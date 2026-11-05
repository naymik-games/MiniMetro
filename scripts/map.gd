# map.gd (root of each map scene)
@tool
extends Node2D

const CELL := 32.0
const BLEED := 600.0   # background extends this far past the playable area
enum MapSize { NORMAL, MEDIUM, LARGE }




## Pick this in the inspector: the bg rect resizes so you can see where to draw.


@export var grid_size := Vector2i(40, 20):
	set(value):
		grid_size = value
		_apply_map_size()
# grey back e9e9e9
# light tan back ffffea
# dark grey 303030
@export var water_fill := Color("#cfe8f7")
@export var water_outline := Color("#7cc4ec")
@export var outline_width: float = 4.0
@export var bend_radius: float = 60.0    ## how round river bends are (0 = sharp)
@export var lake_corner_radius: float = 24.0
@onready var bg: ColorRect = $bg

var _outlines: Node2D
var _water: Array[PackedVector2Array] = []   # global space, union of all water shapes

func _ready() -> void:
	_apply_map_size()
	if Engine.is_editor_hint():
		return   # don't build water shapes (and overwrite river points) in the editor
	var holder := get_node_or_null("Water")

	if holder == null:
		return
	_outlines = Node2D.new()
	_outlines.name = "WaterOutlines"
	add_child(_outlines)
	move_child(_outlines, holder.get_index())   # drawn before (under) the fills
	for node in holder.get_children():
		if node is Line2D:
			_setup_river(node)
		elif node is Polygon2D:
			_setup_lake(node)



# ------------------------------------------------------------ map size

func get_map_pixel_size() -> Vector2:
	return Vector2(grid_size) * CELL

func get_playable_rect() -> Rect2:
	return Rect2(Vector2.ZERO, get_map_pixel_size())

func _apply_map_size() -> void:
	if bg == null:
		return
	if Engine.is_editor_hint():
		# editor: bg = exactly the playable area, so you can see where to draw
		bg.position = Vector2.ZERO
		bg.size = get_map_pixel_size()
	else:
		# in game: bg extends past the edges so wide screens show no gap
		bg.position = Vector2.ONE * -BLEED
		bg.size = get_map_pixel_size() + Vector2.ONE * BLEED * 2.0
# ------------------------------------------------------------ queries

func is_land(pos: Vector2) -> bool:
	for poly in _water:
		if Geometry2D.is_point_in_polygon(pos, poly):
			return false
	return true

## Number of separate water stretches the straight segment a->b passes through.
func water_crossings(a: Vector2, b: Vector2, step := 4.0) -> int:
	var count := 0
	var was_water := not is_land(a)
	var n := maxi(1, ceili(a.distance_to(b) / step))
	for i in range(1, n + 1):
		var is_water := not is_land(a.lerp(b, float(i) / n))
		if is_water and not was_water:
			count += 1
		was_water = is_water
	return count

func random_land_point(rect: Rect2, margin := 30.0) -> Vector2:
	for i in 50:
		var p := Vector2(randf_range(rect.position.x, rect.end.x),
				randf_range(rect.position.y, rect.end.y))
		if is_land(p) and _shore_distance(p) >= margin:
			return p
	return Vector2.INF

func _shore_distance(p: Vector2) -> float:
	var best := INF
	for poly in _water:
		for i in poly.size():
			var c := Geometry2D.get_closest_point_to_segment(
					p, poly[i], poly[(i + 1) % poly.size()])
			best = minf(best, p.distance_to(c))
	return best

# ------------------------------------------------------------ rivers

func _setup_river(line: Line2D) -> void:
	var pts := _round_bends(line.points, bend_radius)
	line.points = pts
	line.default_color = water_fill
	line.joint_mode = Line2D.LINE_JOINT_ROUND
	line.begin_cap_mode = Line2D.LINE_CAP_NONE
	line.end_cap_mode = Line2D.LINE_CAP_NONE
	line.antialiased = true

	# Darker, wider copy behind = the outline
	var outline := Line2D.new()
	outline.points = pts
	outline.width = line.width + outline_width * 2.0
	outline.default_color = water_outline
	outline.joint_mode = Line2D.LINE_JOINT_ROUND
	outline.begin_cap_mode = Line2D.LINE_CAP_NONE
	outline.end_cap_mode = Line2D.LINE_CAP_NONE
	outline.antialiased = true
	#outline.show_behind_parent = true
	#line.add_child(outline)
	outline.global_transform = line.global_transform   # keep it lined up if the river node is moved
	_outlines.add_child(outline)

	# Collision shape = the outer edge of the fill
	for poly in Geometry2D.offset_polyline(pts, line.width * 0.5,
			Geometry2D.JOIN_ROUND, Geometry2D.END_BUTT):
		_water.append(line.global_transform * poly)

## Replaces every interior vertex with a small curve (quadratic bezier).
func _round_bends(pts: PackedVector2Array, radius: float, steps := 8) -> PackedVector2Array:
	if radius <= 0.0 or pts.size() < 3:
		return pts
	var out := PackedVector2Array([pts[0]])
	for i in range(1, pts.size() - 1):
		var p := pts[i]
		var a := pts[i - 1] - p
		var b := pts[i + 1] - p
		if a.length() < 0.001 or b.length() < 0.001:
			continue
		var r := minf(radius, minf(a.length(), b.length()) * 0.5)
		var p0 := p + a.normalized() * r
		var p1 := p + b.normalized() * r
		for s in range(steps + 1):
			var t := float(s) / steps
			out.append(p0.lerp(p, t).lerp(p.lerp(p1, t), t))
	out.append(pts[pts.size() - 1])
	return out

# ------------------------------------------------------------ lakes

func _setup_lake(node: Polygon2D) -> void:
	var poly := node.polygon
	if lake_corner_radius > 0.0:
		# shrink then grow with round joins -> rounded convex corners
		var shrunk := Geometry2D.offset_polygon(poly, -lake_corner_radius, Geometry2D.JOIN_MITER)
		if not shrunk.is_empty():
			var grown := Geometry2D.offset_polygon(shrunk[0], lake_corner_radius, Geometry2D.JOIN_ROUND)
			if not grown.is_empty():
				poly = grown[0]
	node.polygon = poly
	node.color = water_fill
	node.antialiased = true

	var outline := Line2D.new()
	outline.points = poly
	outline.closed = true
	outline.width = outline_width * 2.0   # inner half is hidden under the fill
	outline.default_color = water_outline
	outline.joint_mode = Line2D.LINE_JOINT_ROUND
	outline.antialiased = true
	outline.show_behind_parent = true
	node.add_child(outline)

	_water.append(node.global_transform * poly)
