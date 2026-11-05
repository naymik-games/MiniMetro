# MetroLine.gd
class_name MetroLine
extends Node2D

const TRAIN = preload("uid://d3ejtvnsf4fmt")

@onready var line_2d: Line2D = $Line2D
@onready var track_path: Path2D = $track_path
## Set by game.gd right after the line is instantiated. Needs map.water_crossings(a, b).
signal route_changed  ## emitted at the end of rebuild_track()

var map: Node2D = null
var bridges_used: int = 0  ## bridges this line's committed route needs

## Preference order. Dry shapes exit early, so the middle-diagonal extras are only
## tried when both neat shapes cross water, and only win if strictly better.
@export var path_diagonal_positions: Array[float] = [0.0, 1.0, 0.5, 0.25, 0.75]

var _path_cache: Dictionary = {}  # Vector4(start, end) -> {"path": Array[Vector2], "cost": int}

var is_loop: bool = false
## Committed route. For loops the first station is repeated at the end.
var connected_stations: Array[Area2D] = []
var line_color: Color = Color.RED

## Terminus cap drawn just past each end of an open line (the "grab here" affordance)
@export var cap_offset: float = 18.0
@export var cap_half_length: float = 9.0
## Hover highlight: how much thicker / lighter the line gets
@export var highlight_width_scale: float = 1.6
@export_range(0.0, 1.0) var highlight_lighten: float = 0.2

## Sideways gap between lines that run over the same pair of stations
@export var track_spacing: float = 8.0
## Minimum angle (degrees) between the grab caps of lines ending at the same station
@export var cap_min_separation_deg: float = 60.0
## Corners sharper than this (x the sideways offset) fall back to a small jog instead of a miter
@export var miter_limit: float = 3.0

var _base_width: float = 4.0
var _highlighted: bool = false

# Layout cache. Every line's drawn geometry depends on the other lines (shared hops, cap fanning),
# so one global stamp is bumped whenever any route changes and each line lazily recomputes.
static var _layout_stamp: int = 0
var _route_version: int = -1
var _cap_version: int = -1
var _route_pts: PackedVector2Array = PackedVector2Array()  # committed route, already offset
var _route_station_idx: PackedInt32Array = PackedInt32Array()  # index into _route_pts per station
var _built_points: PackedVector2Array = PackedVector2Array()  # what the train curve was built from
var _cap_angles: Array[float] = [0.0, 0.0]  # [start, end] direction of the grab caps, radians

# Drag preview: a single extra waypoint (the mouse) spliced into the route at _preview_index.
# It only affects what's DRAWN. The train track is built from committed stations only.
var _has_preview: bool = false
var _preview_pos: Vector2 = Vector2.ZERO
var _preview_index: int = 0

# Distance along the track at which each committed station sits
var _station_offsets: PackedFloat32Array = PackedFloat32Array()


func _ready() -> void:
	_base_width = line_2d.width
	add_to_group("metro_lines")
	_invalidate_layouts()

func init_line(start_station: Area2D, color: Color) -> void:
	line_color = color
	connected_stations = [start_station]
	rebuild_track()


## Rebuilds a saved line in one go. No bridge checks: the route was legal when it was saved.
func restore_line(stations: Array[Area2D], color: Color, loop: bool) -> void:
	line_color = color
	connected_stations = stations
	is_loop = loop
	rebuild_track()


# ------------------------------------------------------------ editing API

func add_station_at(station: Area2D, index: int) -> void:
	connected_stations.insert(clampi(index, 0, connected_stations.size()), station)
	rebuild_track()


func remove_station_at(index: int) -> void:
	if index < 0 or index >= connected_stations.size():
		return
	connected_stations.remove_at(index)
	rebuild_track()


## Removes a station wherever it is in the route; neighbours get joined directly.
func remove_station(station: Area2D) -> void:
	if is_loop:
		# Open the loop, remove the station, re-close if there's still a loop to be had
		connected_stations.pop_back()
		is_loop = false
		connected_stations.erase(station)
		if connected_stations.size() >= 3:
			connected_stations.append(connected_stations.front())
			is_loop = true
	else:
		connected_stations.erase(station)
	rebuild_track()


## Puts every rider on this line's trains back on the nearest of the line's stations.
## Call before freeing the line, otherwise they vanish with the trains.
func release_passengers() -> void:
	for child in track_path.get_children():
		if child is PathFollow2D:
			child.call("release_passengers", connected_stations)

func close_loop() -> void:
	if is_loop or connected_stations.size() < 3:
		return
	connected_stations.append(connected_stations.front())
	is_loop = true
	rebuild_track()


## Station count ignoring the repeated closing station of a loop
func distinct_station_count() -> int:
	return connected_stations.size() - (1 if is_loop else 0)


func set_preview(mouse_pos: Vector2, index: int) -> void:
	_has_preview = true
	_preview_pos = mouse_pos
	_preview_index = index
	update_line_visuals()


func clear_preview() -> void:
	_has_preview = false
	update_line_visuals()


# ------------------------------------------------------------ hit testing

## Closest grab cap (stub + crossbar) within `radius` of the mouse.
## Returns {"is_start": bool, "dist": float} or {} if none.
func endpoint_hit(mouse_pos: Vector2, radius: float) -> Dictionary:
	if is_loop or connected_stations.size() < 2:
		return {}
	_ensure_caps()
	if _route_pts.size() < 2:
		return {}
	var best := {}
	var best_dist := radius
	for is_start in [true, false]:
		var cap := _cap_geometry(is_start)
		var origin: Vector2 = cap["origin"]
		var center: Vector2 = cap["center"]
		var side: Vector2 = cap["normal"] * float(cap["half"])
		var d := minf(
			mouse_pos.distance_to(Geometry2D.get_closest_point_to_segment(mouse_pos, origin, center)),
			mouse_pos.distance_to(Geometry2D.get_closest_point_to_segment(mouse_pos, center - side, center + side)))
		if d < best_dist:
			best_dist = d
			best = {"is_start": is_start, "dist": d}
	return best


func check_endpoint_click(mouse_pos: Vector2, click_radius: float = 20.0) -> String:
	var hit := endpoint_hit(mouse_pos, click_radius)
	if hit.is_empty():
		return ""
	return "start" if hit["is_start"] else "end"


## Closest hop (station i -> i+1) to pos, measured against the OFFSET track.
## Returns {"index": int, "dist": float} or {} if nothing within tolerance.
func find_segment_hit(pos: Vector2, tolerance: float) -> Dictionary:
	var best := {}
	var best_dist := tolerance
	for i in range(connected_stations.size() - 1):
		var a: Area2D = connected_stations[i]
		var b: Area2D = connected_stations[i + 1]
		var lateral := _hop_offset(a, b)
		var pts := calculate_mini_metro_path(a.global_position, b.global_position)
		for j in range(pts.size() - 1):
			var shift := _left((pts[j + 1] - pts[j]).normalized()) * lateral
			var closest := Geometry2D.get_closest_point_to_segment(pos, pts[j] + shift, pts[j + 1] + shift)
			var d := pos.distance_to(closest)
			if d < best_dist:
				best_dist = d
				best = {"index": i, "dist": d}
	return best


## Index i of the segment (station i -> station i+1) closest to pos, or -1 if none within tolerance.
func find_segment_index_at(pos: Vector2, tolerance: float) -> int:
	var hit := find_segment_hit(pos, tolerance)
	return -1 if hit.is_empty() else int(hit["index"])


# ------------------------------------------------------------ visuals

## Draws committed route + the mouse preview (if any).
func update_line_visuals() -> void:
	_apply_style()

	if _has_preview and not is_loop:
		var positions: Array[Vector2] = []
		var stations: Array = []
		for station in connected_stations:
			positions.append(station.global_position)
			stations.append(station)
		var at := clampi(_preview_index, 0, positions.size())
		positions.insert(at, _preview_pos)
		stations.insert(at, null)  # the mouse is not a station: no sideways offset on its hops
		line_2d.points = _build_route(positions, stations, false)["points"]
	else:
		_ensure_route()
		line_2d.points = _route_pts
	queue_redraw() # caps


## Called by game.gd when another line was removed.
func refresh_layout() -> void:
	_invalidate_layouts()
	_on_neighbor_changed()


func set_highlighted(value: bool) -> void:
	if _highlighted == value:
		return
	_highlighted = value
	_apply_style()
	queue_redraw()


func _apply_style() -> void:
	line_2d.default_color = line_color.lightened(highlight_lighten) if _highlighted else line_color
	line_2d.width = _base_width * (highlight_width_scale if _highlighted else 1.0)


## Terminus caps: a short stub and a crossbar past each end of an open line.
## Hidden while this line is being dragged, since its end is moving.
func _draw() -> void:
	if is_loop or _has_preview or connected_stations.size() < 2:
		return
	_ensure_caps()
	if _route_pts.size() < 2:
		return
	_draw_cap(_cap_geometry(true))
	_draw_cap(_cap_geometry(false))


func _draw_cap(cap: Dictionary) -> void:
	var color := line_2d.default_color
	var width := line_2d.width
	var half: float = cap["half"] * (highlight_width_scale if _highlighted else 1.0)
	var center: Vector2 = cap["center"]
	var normal: Vector2 = cap["normal"]
	draw_line(cap["origin"], center, color, width, true)
	draw_line(center - normal * half, center + normal * half, color, width * 1.5, true)


## Where a cap sits. Shared by drawing and hit testing so what you see is what you grab.
func _cap_geometry(is_start: bool) -> Dictionary:
	var origin := _route_pts[0] if is_start else _route_pts[_route_pts.size() - 1]
	var dir := Vector2.from_angle(_cap_angles[0 if is_start else 1])
	return {
		"origin": origin,
		"center": origin + dir * cap_offset,
		"normal": _left(dir),
		"half": cap_half_length,
	}


## Direction (radians) a cap would point if nothing else were at this station:
## straight on from the last piece of track.
func _nominal_cap_angle(is_start: bool) -> float:
	_ensure_route()
	var n := _route_pts.size()
	if n < 2:
		return 0.0
	var dir := (_route_pts[0] - _route_pts[1]) if is_start else (_route_pts[n - 1] - _route_pts[n - 2])
	return dir.angle()


func _ensure_caps() -> void:
	_ensure_route()
	if _cap_version == _layout_stamp:
		return
	_cap_version = _layout_stamp
	_cap_angles = [0.0, 0.0]
	if is_loop or connected_stations.size() < 2:
		return

	for is_start in [true, false]:
		var station: Area2D = connected_stations.front() if is_start else connected_stations.back()

		# Every open line that ends on this station, this one included
		var group: Array[Dictionary] = []
		for line in _all_lines():
			if line.is_loop or line.connected_stations.size() < 2:
				continue
			for line_start in [true, false]:
				var end_station: Area2D = line.connected_stations.front() if line_start else line.connected_stations.back()
				if end_station == station:
					group.append({"line": line, "is_start": line_start, "angle": line._nominal_cap_angle(line_start)})

		group.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if not is_equal_approx(a["angle"], b["angle"]):
				return a["angle"] < b["angle"]
			if a["line"] != b["line"]:
				return a["line"].get_index() < b["line"].get_index()
			return a["is_start"] and not b["is_start"])
		_spread_angles(group, deg_to_rad(cap_min_separation_deg))

		for entry in group:
			if entry["line"] == self and entry["is_start"] == is_start:
				_cap_angles[0 if is_start else 1] = entry["angle"]


## Pushes neighbouring angles (sorted, circular) apart until each gap is at least `sep`.
func _spread_angles(items: Array[Dictionary], sep: float) -> void:
	var n := items.size()
	if n < 2:
		return
	sep = minf(sep, TAU / n)
	for _pass in 16:
		var moved := false
		for i in n:
			var a: Dictionary = items[i]
			var b: Dictionary = items[(i + 1) % n]
			var gap: float = b["angle"] - a["angle"]
			if i == n - 1:
				gap += TAU
			if gap < sep - 0.001:
				var push := (sep - gap) * 0.5
				a["angle"] -= push
				b["angle"] += push
				moved = true
		if not moved:
			break


# ------------------------------------------------------------ train track

## Rebuilds the Curve2D from COMMITTED stations only and re-seats any trains on it.
## Call whenever the station list changes (the add/remove helpers above do this for you).
func rebuild_track() -> void:
	_invalidate_layouts()
	_rebuild_curve()
	# Offsets and cap angles of every other line may have changed too
	for other in _all_lines():
		if other != self:
			other._on_neighbor_changed()
	route_changed.emit()  # last line of the function


func _on_neighbor_changed() -> void:
	_ensure_route()
	if _route_pts != _built_points:
		_rebuild_curve()  # also refreshes visuals
	else:
		update_line_visuals()


func _rebuild_curve() -> void:
	_ensure_route()
	bridges_used = _route_cost(_station_positions(connected_stations))

	var curve := Curve2D.new()
	var cumulative := PackedFloat32Array()
	var run := 0.0
	for k in _route_pts.size():
		if k > 0:
			run += _route_pts[k].distance_to(_route_pts[k - 1])
		cumulative.append(run)
		curve.add_point(_route_pts[k])
	var offsets := PackedFloat32Array()
	for idx in _route_station_idx:
		offsets.append(cumulative[idx])
	_station_offsets = offsets
	_built_points = _route_pts

	# Remember where every train physically is before swapping the curve
	var trains: Array[PathFollow2D] = []
	var world_positions: Array[Vector2] = []
	for child in track_path.get_children():
		var train := child as PathFollow2D
		if train:
			trains.append(train)
			world_positions.append(train.global_position)

	track_path.curve = curve

	for i in trains.size():
		var new_progress := curve.get_closest_offset(track_path.to_local(world_positions[i]))
		trains[i].call("on_route_changed", _station_offsets, new_progress, is_loop)

	update_line_visuals()


func spawn_train(start_offset: float = 0.0) -> Train:
	if connected_stations.size() < 2:
		return null
	var new_train = TRAIN.instantiate()
	track_path.add_child(new_train)
	var visual = new_train.get_child(0)
	new_train.color = line_color
	#if visual is Sprite2D:
		#visual.modulate = line_color
	new_train.call("on_route_changed", _station_offsets, start_offset, is_loop)
	return new_train

# ------------------------------------------------------------ shared-track layout

static func _invalidate_layouts() -> void:
	_layout_stamp += 1


static func _is_canonical(a: Vector2, b: Vector2) -> bool:
	return a.x < b.x or (is_equal_approx(a.x, b.x) and a.y <= b.y)


static func _left(dir: Vector2) -> Vector2:
	return Vector2(-dir.y, dir.x)


func _all_lines() -> Array[MetroLine]:
	var out: Array[MetroLine] = []
	if not is_inside_tree():
		out.append(self)
		return out
	for node in get_tree().get_nodes_in_group("metro_lines"):
		var line := node as MetroLine
		if line != null and not line.is_queued_for_deletion():
			out.append(line)
	out.sort_custom(func(a: MetroLine, b: MetroLine) -> bool: return a.get_index() < b.get_index())
	return out


func uses_hop(a: Area2D, b: Area2D) -> bool:
	for i in range(connected_stations.size() - 1):
		var x := connected_stations[i]
		var y := connected_stations[i + 1]
		if (x == a and y == b) or (x == b and y == a):
			return true
	return false


## Sideways shift (in the left-hand normal of the direction of travel a -> b) for this line.
## Lines sharing the hop fan out symmetrically around the station-to-station centre line.
func _hop_offset(a: Area2D, b: Area2D) -> float:
	if a == null or b == null:
		return 0.0
	var sharing: Array[MetroLine] = []
	for line in _all_lines():
		if line.uses_hop(a, b):
			sharing.append(line)
	if sharing.size() < 2:
		return 0.0
	var slot := sharing.find(self)
	if slot == -1:
		return 0.0
	var s := (slot - (sharing.size() - 1) * 0.5) * track_spacing
	# Slots are defined relative to the canonical direction; flip for lines travelling the other way
	return s if _is_canonical(a.global_position, b.global_position) else -s


func _ensure_route() -> void:
	if _route_version == _layout_stamp:
		return
	_route_version = _layout_stamp
	var positions: Array[Vector2] = []
	var stations: Array = []
	for station in connected_stations:
		positions.append(station.global_position)
		stations.append(station)
	var route := _build_route(positions, stations, is_loop)
	_route_pts = route["points"]
	_route_station_idx = route["station_idx"]


## Full offset polyline through the waypoints. `stations[i]` is the Area2D at positions[i], or null
## for a free point (the drag preview). Returns {"points", "station_idx"}.
func _build_route(positions: Array[Vector2], stations: Array, closed: bool) -> Dictionary:
	var chain: Array[Vector2] = []
	var ds: Array[float] = []
	var chain_idx := PackedInt32Array()
	if positions.is_empty():
		return {"points": PackedVector2Array(), "station_idx": chain_idx}

	chain.append(positions[0])
	chain_idx.append(0)
	for i in range(1, positions.size()):
		var lateral := _hop_offset(stations[i - 1], stations[i])
		var seg := calculate_mini_metro_path(positions[i - 1], positions[i])
		for j in range(1, seg.size()):
			if seg[j].distance_to(chain[chain.size() - 1]) < 0.01:
				continue
			chain.append(seg[j])
			ds.append(lateral)
		chain_idx.append(chain.size() - 1)

	var shifted := _offset_chain(chain, ds, closed)
	var first_idx: PackedInt32Array = shifted["first_idx"]
	var station_idx := PackedInt32Array()
	for c in chain_idx:
		station_idx.append(first_idx[c])
	return {"points": shifted["points"], "station_idx": station_idx}


## Shifts every piece of a polyline sideways by its own distance (ds[k] for piece k -> k+1) and
## stitches the pieces back together with mitered corners. Returns {"points", "first_idx"}.
func _offset_chain(pts: Array[Vector2], ds: Array[float], closed: bool) -> Dictionary:
	var out := PackedVector2Array()
	var first_idx := PackedInt32Array()
	var n := pts.size()
	if n < 2:
		for p in pts:
			out.append(p)
			first_idx.append(out.size() - 1)
		return {"points": out, "first_idx": first_idx}

	var dirs: Array[Vector2] = []
	for k in n - 1:
		dirs.append((pts[k + 1] - pts[k]).normalized())

	for k in n:
		var vertex: Array[Vector2] = []
		if k == 0:
			if closed:
				vertex = _join(pts[0], dirs[n - 2], ds[n - 2], dirs[0], ds[0])
			else:
				vertex.append(pts[0] + _left(dirs[0]) * ds[0])
		elif k == n - 1:
			if closed:
				vertex = _join(pts[k], dirs[k - 1], ds[k - 1], dirs[0], ds[0])
			else:
				vertex.append(pts[k] + _left(dirs[k - 1]) * ds[k - 1])
		else:
			vertex = _join(pts[k], dirs[k - 1], ds[k - 1], dirs[k], ds[k])

		var before := out.size()
		for v in vertex:
			if out.is_empty() or not out[out.size() - 1].is_equal_approx(v):
				out.append(v)
		first_idx.append(before if out.size() > before else out.size() - 1)
	return {"points": out, "first_idx": first_idx}


## Corner at `p` between a piece heading dir_a (shifted d_a) and one heading dir_b (shifted d_b).
## Usually one mitered point; two points (a small jog) when parallel or the miter would spike.
func _join(p: Vector2, dir_a: Vector2, d_a: float, dir_b: Vector2, d_b: float) -> Array[Vector2]:
	var a := p + _left(dir_a) * d_a
	var b := p + _left(dir_b) * d_b
	var result: Array[Vector2] = []
	if a.is_equal_approx(b):
		result.append(a)
		return result
	var cross := dir_a.cross(dir_b)
	if absf(cross) > 0.01:
		var t := (b - a).cross(dir_b) / cross
		var m := a + dir_a * t
		if m.distance_to(p) <= miter_limit * maxf(absf(d_a), absf(d_b)):
			result.append(m)
			return result
	result.append(a)
	result.append(b)
	return result


# ------------------------------------------------------------ path maths (unchanged)

func calculate_mini_metro_path(start_pos: Vector2, end_pos: Vector2) -> Array[Vector2]:
	var path: Array[Vector2] = _resolve_segment(start_pos, end_pos)["path"]
	return path


## Best path for one hop plus the bridges it needs. Cached.
func _resolve_segment(start_pos: Vector2, end_pos: Vector2) -> Dictionary:
	# Always solve a hop in one canonical direction so A->B and B->A trace the same track.
	# Without this, two lines over the same stations can pick different shapes and never overlap.
	if not _is_canonical(start_pos, end_pos):
		var flipped := _resolve_segment(end_pos, start_pos)
		var reversed_path: Array[Vector2] = []
		reversed_path.assign(flipped["path"])
		reversed_path.reverse()
		return {"path": reversed_path, "cost": flipped["cost"]}

	var key := Vector4(start_pos.x, start_pos.y, end_pos.x, end_pos.y)
	if _path_cache.has(key):
		return _path_cache[key]

	var best: Array[Vector2] = []
	var best_cost := 1 << 30
	for t in path_diagonal_positions:
		var candidate := _build_path(start_pos, end_pos, t)
		var cost := _bridge_cost(candidate)
		if cost < best_cost:
			best = candidate
			best_cost = cost
		if best_cost == 0:
			break

	if _path_cache.size() > 512:  # drag previews add a key on every mouse move
		_path_cache.clear()
	var entry := {"path": best, "cost": best_cost}
	_path_cache[key] = entry
	return entry


func _bridge_cost(path: Array[Vector2]) -> int:
	if map == null:
		return 0
	var total := 0
	for i in path.size() - 1:
		total += int(map.water_crossings(path[i], path[i + 1]))
	return total


# ---- bridge accounting: trial routes, so game.gd can ask "what would this cost?"

func _station_positions(stations: Array) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for s in stations:
		out.append(s.global_position)
	return out


func _route_cost(positions: Array[Vector2]) -> int:
	var total := 0
	for i in range(1, positions.size()):
		total += _resolve_segment(positions[i - 1], positions[i])["cost"]
	return total


## Change in this line's bridge use if `station` were spliced in at `index`.
func bridge_delta_if_added(station: Area2D, index: int) -> int:
	var trial := connected_stations.duplicate()
	trial.insert(clampi(index, 0, trial.size()), station)
	return _route_cost(_station_positions(trial)) - bridges_used


## Same, for the drag preview (the mouse acts as a temporary station).
func bridge_delta_for_preview(mouse_pos: Vector2, index: int) -> int:
	var points := _station_positions(connected_stations)
	points.insert(clampi(index, 0, points.size()), mouse_pos)
	return _route_cost(points) - bridges_used


func bridge_delta_if_closed() -> int:
	if is_loop or connected_stations.size() < 3:
		return 0
	var trial := connected_stations.duplicate()
	trial.append(trial.front())
	return _route_cost(_station_positions(trial)) - bridges_used


## Removing a station joins its neighbours directly, which can need MORE water than before.
func bridge_delta_if_removed(station: Area2D) -> int:
	var trial := connected_stations.duplicate()
	if is_loop:
		trial.pop_back()
		trial.erase(station)
		if trial.size() >= 3:
			trial.append(trial.front())
	else:
		trial.erase(station)
	return _route_cost(_station_positions(trial)) - bridges_used

## t = 0 puts the diagonal first (your original behaviour), t = 1 puts it last.
func _build_path(start_pos: Vector2, end_pos: Vector2, t: float) -> Array[Vector2]:
	var points: Array[Vector2] = [start_pos]
	var delta := end_pos - start_pos
	var abs_x := absf(delta.x)
	var abs_y := absf(delta.y)

	if abs_x == 0 or abs_y == 0 or is_equal_approx(abs_x, abs_y):
		points.append(end_pos)
		return points

	var dir := Vector2(signf(delta.x), signf(delta.y))
	var diagonal := minf(abs_x, abs_y)
	var straight := absf(abs_x - abs_y)
	var straight_dir := Vector2(dir.x, 0.0) if abs_x > abs_y else Vector2(0.0, dir.y)

	var first := start_pos + straight_dir * straight * t
	var second := first + dir * diagonal
	if not first.is_equal_approx(start_pos):
		points.append(first)
	if not second.is_equal_approx(end_pos):
		points.append(second)
	points.append(end_pos)
	return points


## Closest point on the committed track to `pos` (world space).
## Returns {} if there's no track or it's farther than `tolerance`.
func probe_track(pos: Vector2, tolerance: float) -> Dictionary:
	var curve := track_path.curve
	if curve == null or curve.point_count < 2:
		return {}
	var offset := curve.get_closest_offset(track_path.to_local(pos))
	var point := track_path.to_global(curve.sample_baked(offset))
	if pos.distance_to(point) > tolerance:
		return {}
	var length := curve.get_baked_length()
	var a := track_path.to_global(curve.sample_baked(maxf(offset - 2.0, 0.0)))
	var b := track_path.to_global(curve.sample_baked(minf(offset + 2.0, length)))
	return {"offset": offset, "point": point, "angle": (b - a).angle()}


func get_occupied_grid_cells(cell_size: int) -> Array[Vector2i]:
	var occupied_cells: Array[Vector2i] = []
	if connected_stations.size() < 2:
		return occupied_cells

	for i in range(connected_stations.size() - 1):
		var start_pixel = connected_stations[i].global_position
		var end_pixel = connected_stations[i + 1].global_position
		var segment_points = calculate_mini_metro_path(start_pixel, end_pixel)

		for j in range(segment_points.size() - 1):
			var sub_start = Vector2i(floori(segment_points[j].x / cell_size), floori(segment_points[j].y / cell_size))
			var sub_end = Vector2i(floori(segment_points[j + 1].x / cell_size), floori(segment_points[j + 1].y / cell_size))
			var line_cells = rasterize_grid_line(sub_start, sub_end)
			for cell in line_cells:
				if not cell in occupied_cells:
					occupied_cells.append(cell)
	return occupied_cells


func rasterize_grid_line(start: Vector2i, end: Vector2i) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var current = start
	cells.append(current)
	var delta = end - start
	var step_x = sign(delta.x)
	var step_y = sign(delta.y)
	if delta.x == 0 and delta.y == 0:
		return cells
	var total_steps = max(abs(delta.x), abs(delta.y))
	for i in range(total_steps):
		current.x += step_x if delta.x != 0 else 0
		current.y += step_y if delta.y != 0 else 0
		cells.append(current)
	return cells


#func serves_type(shape: String) -> bool:
	#for s in connected_stations:
		#if s.type == shape:
			#return true
	#return false
