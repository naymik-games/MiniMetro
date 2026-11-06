# LineManager.gd
extends Node2D

@export var fallback_config: GameConfig  ## only used when you run game.tscn directly (F6)
## How close (px) the ghost must be to a line's track to drop onto it.
@export var locomotive_drop_radius: float = 24.0
@export var carriage_drop_radius: float = 30.0
var _ghost_upgrade: StringName = &""

const METRO_LINE_SCENE = preload("res://scenes/metro_line.tscn")
const STATION = preload("uid://cfs58w7ivwk4p")
const BUTTON_SIZE := Vector2(56,56)
enum DragMode {
	NONE,
	EXTEND_END,    # dragging from the last station of a line
	EXTEND_START,  # dragging from the first station of a line
	INSERT,        # dragging out of the middle of a line to splice stations in
}

## How close (px) a press must be to a line's end station to grab that end.
@export var handle_grab_radius: float = 28.0
## How close (px) a press must be to a line's track to grab the middle of it.
@export var segment_grab_radius: float = 14.0
## Dragging back along the track at least this far (px) from the end station retracts that station.
@export var backtrack_distance: float = 40.0

@onready var spawner: Node2D = $StationSpawner
var map: Node2D
var config: GameConfig
var available_colors: Array[Color] = [
	Color("#EE352E"), # Red (1/2/3)
	Color("#00933C"), # Green (4/5/6)
	Color("#B933AD"), # Purple (7)
	Color("#0039A6"), # Blue (A/C/E)
	Color("#FF6319"), # Orange (B/D/F/M)
	Color("#FCCC0A"), # Yellow (N/Q/R/W)
	Color("#996633")  # Brown (J/Z)
]

var active_lines: Array[MetroLine] = []
# #ffd205,#f03222,#224390,#0d9fd0,#068939,#e88194,#a65a36
#:root {
  #--palette-color-1: #FFD205;
  #--palette-color-2: #F13323;
  #--palette-color-3: #234491;
  #--palette-color-4: #0E9FD4;
  #--palette-color-5: #068939;
  #--palette-color-6: #E98297;
  #--palette-color-7: #A75B37;

  #--palette-color-8: #EDEDEF; land
  #--palette-color-9: #C4E5F8; water
  #--palette-color-10: #6AC8EC; shore
#}


# --- Drag state ---
var drag_mode: DragMode = DragMode.NONE
var drag_line: MetroLine = null
var drag_insert_index: int = 0     # INSERT only: index where the next station will be spliced in
var drag_inserted_count: int = 0   # INSERT only: stations added this drag (only these can be backtracked)
var _press_screen_pos := Vector2.ZERO   # viewport-space position of the last press (for panning)
var hovered_line: MetroLine = null
@onready var camera_2d: MapCamera = $Camera2D
@onready var hud: CanvasLayer = $HUD

@export_group("Camera Fit")
## Screen space (viewport units) the HUD bars cover. Tune by eye.
@export var hud_margin_left := 80.0     # upgrade bar
@export var hud_margin_right := 32.0    # line bar
@export var hud_margin_top := 0.0
@export var hud_margin_bottom := 0.0

var line_bar: LineBar
var slot_colors: Array[Color] = []  ## the colours of the lines this map allows

var score: int = 0
var score_label: Label
var _game_over: bool = false
var director: DemandDirector
var upgrade_bar: UpgradeBar
var clock_hud: ClockHud
var _reward_screen: RewardScreen = null
var _ghost: LocomotiveGhost = null
var _station_upgrade_armed: bool = false  ## station upgrade selected, waiting for a station click
var bridge_budget: int = 0
var _save_id: String = ""
var _mode: int = SaveManager.Mode.CLASSIC  ## Classic or Endless, from the home screen
var _best_before: int = 0     ## this map's high score when the run started (for "New best!")
var _loaded: bool = false     ## autosave stays off until startup / restore has finished


func _ready() -> void:
	config = GameSession.current_config if GameSession.current_config else fallback_config
	if config == null or config.map_scene == null:
		push_error("game.gd: no config / map scene to load.")
		return

	add_to_group("game")
	_save_id = config.get_save_id()
	_mode = GameSession.current_mode
	_best_before = SaveManager.get_high_score(_save_id)

	# The home screen's "Resume" sets this flag. It is consumed here, so reloading
	# the scene ("Play again") always starts a fresh game.
	var save: Dictionary = {}
	if GameSession.resume_requested:
		save = SaveManager.get_run(_save_id, _mode)
	GameSession.resume_requested = false
	var resuming := not save.is_empty()

	_build_score_label()
	_build_menu_button()

	var slot_count := clampi(int(save.get("slot_count", config.starting_lines)), 1, available_colors.size())
	slot_colors.assign(available_colors.slice(0, slot_count))

	line_bar = LineBar.new()
	hud.add_child(line_bar)
	line_bar.setup(slot_colors)

	upgrade_bar = UpgradeBar.new()
	hud.add_child(upgrade_bar)
	bridge_budget = int(save.get("bridge_budget", config.starting_bridges))
	var counts = config.get_starting_upgrade_counts()
	var saved_counts: Dictionary = save.get("upgrades", {})
	for id in counts.keys():
		counts[id] = int(saved_counts.get(String(id), counts[id]))
	counts[&"bridge"] = bridge_budget
	upgrade_bar.setup(counts)
	upgrade_bar.upgrade_pressed.connect(_on_upgrade_pressed)
	upgrade_bar.upgrade_grabbed.connect(_on_upgrade_grabbed)

	GameClock.reset()
	if resuming:
		GameClock.restore(int(save.get("day", 0)), float(save.get("day_progress", 0.0)))
	clock_hud = ClockHud.new()
	hud.add_child(clock_hud)
	GameClock.week_started.connect(_on_week_started)
	GameClock.day_started.connect(_on_day_started)
	map = config.map_scene.instantiate()
	add_child(map)
	move_child(map, 0)  # draw behind stations and lines
	
	clock_hud.hud_visibility_toggled.connect(func(v: bool): upgrade_bar.visible = v)
	
	_apply_map_size()

	# The director has to exist before the stations do: a station looks it up when it spawns.
	director = DemandDirector.new()
	add_child(director)
	director.setup(config, spawner, hud)

	spawner.line_manager = self
	await spawner.start(map, config, save.get("spawner", {}))

	if resuming:
		_restore_run(save)
	_loaded = true


func _apply_map_size() -> void:
	camera_2d.setup(map.get_map_pixel_size())
	if not camera_2d.pinch_started.is_connected(_on_pinch_started):
		camera_2d.pinch_started.connect(_on_pinch_started)


func _on_pinch_started() -> void:
	# A second finger landed: abandon whatever the first finger was doing
	_cancel_upgrade_drag()
	if drag_mode != DragMode.NONE:
		_end_drag()

func _fit_camera() -> void:
	if map == null:
		return
	var vp := get_viewport_rect().size
	var world: Vector2 = map.get_map_pixel_size()
	var avail := Vector2(vp.x - hud_margin_left - hud_margin_right,
			vp.y - hud_margin_top - hud_margin_bottom)
	var z := minf(avail.x / world.x, avail.y / world.y)
	camera_2d.zoom = Vector2(z, z)

	# Put the map's centre at the centre of the free (non-HUD) area
	var free_center := Vector2(hud_margin_left, hud_margin_top) + avail * 0.5
	camera_2d.position = world * 0.5 + (vp * 0.5 - free_center) / z


# ---------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if not camera_2d.is_pinching():
					_press_screen_pos = mb.position
					_begin_drag(get_global_mouse_position())
			else:
				camera_2d.end_pan()
				if drag_mode != DragMode.NONE:
					_end_drag()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			if _station_upgrade_armed:
				_set_station_upgrade_armed(false)
			else:
				_remove_station_at(get_global_mouse_position())

	elif event is InputEventMouseMotion:
		if camera_2d.is_pinching():
			return
		var mm := event as InputEventMouseMotion
		if camera_2d.is_panning():
			camera_2d.pan_move(mm.position)
		elif drag_mode != DragMode.NONE:
			_update_drag(get_global_mouse_position())
		else:
			_update_hover(get_global_mouse_position())


func _begin_drag(mouse_pos: Vector2) -> void:
	# Station upgrade armed: this click picks the station to upgrade, nothing else
	if _station_upgrade_armed:
		_apply_station_upgrade(mouse_pos)
		return

	# 1. Grab the end of an existing line (extend it, or drag back over it to shorten it)
	var handle := find_clicked_line_handle(mouse_pos)
	if not handle.is_empty():
		drag_line = handle["line"]
		drag_mode = DragMode.EXTEND_START if handle["is_start"] else DragMode.EXTEND_END
		_update_drag(mouse_pos)
		return

	# 2. Press on a station -> brand new line
	var station := get_station_at_position(mouse_pos)
	if station:
		start_new_line(station)
		return

	# 3. Press on the middle of a line -> pull it towards other stations (insert)
	var seg := _find_line_segment_at(mouse_pos)
	if not seg.is_empty():
		drag_line = seg["line"]
		drag_mode = DragMode.INSERT
		drag_insert_index = int(seg["index"]) + 1
		drag_inserted_count = 0
		_update_drag(mouse_pos)
		return
	# 4. Press on empty map -> pan the camera
	camera_2d.begin_pan(_press_screen_pos)

func _update_drag(mouse_pos: Vector2) -> void:
	if drag_line == null:
		return

	_set_hovered_line(drag_line) # keep the line being edited highlighted

	# Hovering the previous station retracts the line; otherwise try to grow it.
	if not _try_backtrack(mouse_pos):
		_connect_stations_along_path(mouse_pos)

	var index := _preview_index()
	if drag_line.bridge_delta_for_preview(mouse_pos, index) > bridges_remaining():
		drag_line.clear_preview()
	else:
		drag_line.set_preview(mouse_pos, index)


func _end_drag() -> void:
	var line := drag_line
	var mode := drag_mode
	drag_mode = DragMode.NONE
	drag_line = null
	if line == null:
		return

	line.clear_preview()

	# Release on the opposite end of the line -> close it into a loop
	if mode == DragMode.EXTEND_END or mode == DragMode.EXTEND_START:
		var hover := get_station_at_position(get_global_mouse_position())
		var stations := line.connected_stations
		if hover != null and stations.size() >= 3:
			var closes_from_end = mode == DragMode.EXTEND_END and hover == stations.front()
			var closes_from_start = mode == DragMode.EXTEND_START and hover == stations.back()
			if closes_from_end or closes_from_start:
				if line.bridge_delta_if_closed() <= bridges_remaining():
					line.close_loop()

	# Backtracked all the way (or never left the first station) -> discard the line
	if line.distinct_station_count() < 2:
		delete_line(line)
		return

	if line.track_path.get_child_count() == 0:
		line.spawn_train()

	# Re-balance track spacing on every line
	for l in active_lines:
		l.update_line_visuals()

	_update_hover(get_global_mouse_position())


# ------------------------------------------------------------ hover

## Mirrors what a press would grab: end handle > station (new line, no highlight) > track.
func _update_hover(mouse_pos: Vector2) -> void:
	if _ghost != null:
		return
	var new_hover: MetroLine = null
	var over_handle := false

	var handle := find_clicked_line_handle(mouse_pos)
	if not handle.is_empty():
		new_hover = handle["line"]
		over_handle = true
	elif get_station_at_position(mouse_pos) == null:
		var seg := _find_line_segment_at(mouse_pos)
		if not seg.is_empty():
			new_hover = seg["line"]

	_set_hovered_line(new_hover)
	Input.set_default_cursor_shape(Input.CURSOR_POINTING_HAND if over_handle else Input.CURSOR_ARROW)


func _set_hovered_line(line: MetroLine) -> void:
	if line == hovered_line:
		return
	if is_instance_valid(hovered_line):
		hovered_line.set_highlighted(false)
	hovered_line = line
	if hovered_line != null:
		hovered_line.set_highlighted(true)


# ------------------------------------------------------ drag mechanics

## Retracts the dragged end once for every previous station the drag path has reached.
## Uses the whole anchor -> mouse path (not just the cell under the cursor), so a fast
## drag that jumps over a station's cell still backtracks. Returns true if anything was removed.
func _try_backtrack(mouse_pos: Vector2) -> bool:
	var removed := false
	for _i in 8: # safety cap
		var prev := _get_prev_station()
		if prev == null:
			break
		var anchor := _get_anchor_station()
		var reached_prev := _path_passes_through_station(anchor.global_position, mouse_pos, prev)
		if not reached_prev and not _is_retreating_along_track(mouse_pos, anchor, prev):
			break
		_remove_anchor_station()
		removed = true
	return removed


## True when the cursor has moved back onto the existing track between `prev` and `anchor`
## and is far enough from the anchor to count as a deliberate retreat (not jitter).
func _is_retreating_along_track(mouse_pos: Vector2, anchor: Area2D, prev: Area2D) -> bool:
	if mouse_pos.distance_to(anchor.global_position) < backtrack_distance:
		return false

	# Same orientation the committed track was built with (route order)
	var track: Array[Vector2]
	if drag_mode == DragMode.EXTEND_START:
		track = drag_line.calculate_mini_metro_path(anchor.global_position, prev.global_position)
	else:
		track = drag_line.calculate_mini_metro_path(prev.global_position, anchor.global_position)

	for i in range(track.size() - 1):
		var closest := Geometry2D.get_closest_point_to_segment(mouse_pos, track[i], track[i + 1])
		if mouse_pos.distance_to(closest) <= segment_grab_radius:
			return true
	return false


## The station "behind" the anchor, i.e. the one we'd fall back to when retracting. Null if none.
func _get_prev_station() -> Area2D:
	var stations := drag_line.connected_stations
	match drag_mode:
		DragMode.EXTEND_END:
			if stations.size() >= 2:
				return stations[stations.size() - 2]
		DragMode.EXTEND_START:
			if stations.size() >= 2:
				return stations[1]
		DragMode.INSERT:
			# Only undo stations added during this drag, never the original route
			if drag_inserted_count > 0:
				return stations[drag_insert_index - 2]
	return null


func _remove_anchor_station() -> void:
	var stations := drag_line.connected_stations
	match drag_mode:
		DragMode.EXTEND_END:
			drag_line.remove_station_at(stations.size() - 1)
		DragMode.EXTEND_START:
			drag_line.remove_station_at(0)
		DragMode.INSERT:
			drag_line.remove_station_at(drag_insert_index - 1)
			drag_insert_index -= 1
			drag_inserted_count -= 1


func _path_passes_through_station(start_pixel: Vector2, end_pixel: Vector2, station: Area2D) -> bool:
	if not spawner:
		return false
	var cell_size: int = spawner.cell_size
	var target := Vector2i(floori(station.global_position.x / cell_size), floori(station.global_position.y / cell_size))
	var segment_points := drag_line.calculate_mini_metro_path(start_pixel, end_pixel)

	for i in range(segment_points.size() - 1):
		var sub_start := Vector2i(floori(segment_points[i].x / cell_size), floori(segment_points[i].y / cell_size))
		var sub_end := Vector2i(floori(segment_points[i + 1].x / cell_size), floori(segment_points[i + 1].y / cell_size))
		if target in drag_line.rasterize_grid_line(sub_start, sub_end):
			return true
	return false


## Connects every unlinked station the dragged path passes through, in order.
## Connects every unlinked station the dragged path passes through, in order.
func _connect_stations_along_path(mouse_pos: Vector2) -> void:
	for _i in 8: # safety cap in case the mouse teleports across the map
		var anchor := _get_anchor_station()
		var found := _find_first_unlinked_station_on_path(anchor.global_position, mouse_pos)
		if found == null:
			return

		# --- WATER CHECK & RESOURCE GATEWAY ---
		# Not enough bridges for this hop: stop extending here.
		if drag_line.bridge_delta_if_added(found, _preview_index()) > bridges_remaining():
			return
		# --------------------------------------

		match drag_mode:
			DragMode.EXTEND_END:
				drag_line.add_station_at(found, drag_line.connected_stations.size())
			DragMode.EXTEND_START:
				drag_line.add_station_at(found, 0)
			DragMode.INSERT:
				drag_line.add_station_at(found, drag_insert_index)
				drag_insert_index += 1
				drag_inserted_count += 1

#func _connect_stations_along_path(mouse_pos: Vector2) -> void:
	#for _i in 8: # safety cap in case the mouse teleports across the map
		#var anchor := _get_anchor_station()
		#var found := _find_first_unlinked_station_on_path(anchor.global_position, mouse_pos)
		#if found == null:
			#return
#
		#match drag_mode:
			#DragMode.EXTEND_END:
				#drag_line.add_station_at(found, drag_line.connected_stations.size())
			#DragMode.EXTEND_START:
				#drag_line.add_station_at(found, 0)
			#DragMode.INSERT:
				#drag_line.add_station_at(found, drag_insert_index)
				#drag_insert_index += 1
				#drag_inserted_count += 1


## The station the preview currently grows out of.
func _get_anchor_station() -> Area2D:
	var stations := drag_line.connected_stations
	match drag_mode:
		DragMode.EXTEND_START:
			return stations.front()
		DragMode.INSERT:
			return stations[drag_insert_index - 1]
	return stations.back()


## Where the mouse waypoint sits in the line's station order.
func _preview_index() -> int:
	match drag_mode:
		DragMode.EXTEND_END:
			return drag_line.connected_stations.size()
		DragMode.EXTEND_START:
			return 0
		DragMode.INSERT:
			return drag_insert_index
	return -1


func _find_first_unlinked_station_on_path(start_pixel: Vector2, end_pixel: Vector2) -> Area2D:
	if not spawner:
		return null

	var cell_size: int = spawner.cell_size
	var segment_points := drag_line.calculate_mini_metro_path(start_pixel, end_pixel)

	for i in range(segment_points.size() - 1):
		var sub_start := Vector2i(floori(segment_points[i].x / cell_size), floori(segment_points[i].y / cell_size))
		var sub_end := Vector2i(floori(segment_points[i + 1].x / cell_size), floori(segment_points[i + 1].y / cell_size))

		for cell in drag_line.rasterize_grid_line(sub_start, sub_end):
			if spawner.stations_grid.has(cell):
				var found: Area2D = spawner.stations_grid[cell]
				if not found in drag_line.connected_stations:
					return found
	return null


# ------------------------------------------------------ line management

func start_new_line(station: Area2D) -> void:
	var free_colors := _free_line_colors()
	if free_colors.is_empty():
		return  # every line is in use

	var new_line: MetroLine = METRO_LINE_SCENE.instantiate()
	new_line.map = map
	new_line.route_changed.connect(_refresh_bridges)
	add_child(new_line)
	new_line.init_line(station, free_colors.front())
	active_lines.append(new_line)
	_refresh_line_bar()

	drag_line = new_line
	drag_mode = DragMode.EXTEND_END
	_update_drag(get_global_mouse_position())


func delete_line(line: MetroLine) -> void:
	if hovered_line == line:
		hovered_line = null
	active_lines.erase(line)
	_refresh_bridges()
	line.release_passengers()
	line.queue_free()
	for other in active_lines:
		other.refresh_layout()  # remaining lines may no longer share tracks / caps
	_refresh_line_bar()


## Slot colours not currently used by an active line, in slot order.
func _free_line_colors() -> Array[Color]:
	var used: Array[Color] = []
	for line in active_lines:
		used.append(line.line_color)
	var free: Array[Color] = []
	for color in slot_colors:
		if not color in used:
			free.append(color)
	return free


func _refresh_line_bar() -> void:
	var used: Array[Color] = []
	for line in active_lines:
		used.append(line.line_color)
	line_bar.refresh(used)


## Right-click a station to take it out of a line (the neighbours get joined up).
## If several lines pass through it, the most recently drawn one loses it.
func _remove_station_at(mouse_pos: Vector2) -> void:
	if drag_mode != DragMode.NONE:
		return
	var station := get_station_at_position(mouse_pos)
	if station == null:
		return

	for i in range(active_lines.size() - 1, -1, -1):
		var line := active_lines[i]
		if station in line.connected_stations:
			if line.bridge_delta_if_removed(station) > bridges_remaining():
				return
			line.remove_station(station)
			return


## Closest grab cap under the cursor (ties go to the topmost line).
func find_clicked_line_handle(mouse_pos: Vector2) -> Dictionary:
	var best := {}
	var best_dist := INF
	for i in range(active_lines.size() - 1, -1, -1):
		var hit = active_lines[i].endpoint_hit(mouse_pos, handle_grab_radius)
		if hit.is_empty():
			continue
		if hit["dist"] < best_dist:
			best_dist = hit["dist"]
			best = {"line": active_lines[i], "is_start": hit["is_start"]}
	return best


## Closest track under the cursor. Lines sharing a hop are drawn side by side now,
## so "topmost wins" would make the lower one ungrabbable.
func _find_line_segment_at(mouse_pos: Vector2) -> Dictionary:
	var best := {}
	var best_dist := INF
	for i in range(active_lines.size() - 1, -1, -1):
		var hit = active_lines[i].find_segment_hit(mouse_pos, segment_grab_radius)
		if hit.is_empty():
			continue
		if hit["dist"] < best_dist:
			best_dist = hit["dist"]
			best = {"line": active_lines[i], "index": hit["index"]}
	return best


func get_station_at_position(mouse_pixel_pos: Vector2) -> Area2D:
	if not spawner:
		return null
	var cell_size = spawner.cell_size
	var grid_x = floori(mouse_pixel_pos.x / cell_size)
	var grid_y = floori(mouse_pixel_pos.y / cell_size)
	var target_cell = Vector2i(grid_x, grid_y)

	if spawner.stations_grid.has(target_cell):
		return spawner.stations_grid[target_cell]
	return null


## Calculates a perpendicular pixel offset vector for a line sharing a track segment
func get_line_offset_for_segment(station_a: Area2D, station_b: Area2D, target_line: Node2D) -> Vector2:
	var sharing_lines: Array[Node2D] = []

	# 1. Find all active lines passing between these two specific stations
	for line in active_lines:
		# Safety check: ensure BOTH stations exist anywhere inside this line's route array
		if not (station_a in line.connected_stations and station_b in line.connected_stations):
			continue

		# Check if they are adjacent neighbors inside this line's route array
		var idx_a = line.connected_stations.find(station_a)
		var idx_b = line.connected_stations.find(station_b)

		if abs(idx_a - idx_b) == 1:
			sharing_lines.append(line)

	if sharing_lines.size() <= 1:
		return Vector2.ZERO # Lone line, keep centered on station coordinates

	# 2. FIX: Sort lines by their color red-values to ensure stable indexing
	sharing_lines.sort_custom(func(a, b): return a.line_color.r < b.line_color.r)

	var line_index = sharing_lines.find(target_line)
	if line_index == -1:
		return Vector2.ZERO

	# 3. Calculate the step offset multipliers
	var center_index = (sharing_lines.size() - 1) / 2.0
	var multiplier = line_index - center_index

	# 4. Calculate perpendicular direction vector
	var pos_a = station_a.global_position
	var pos_b = station_b.global_position

	# Enforce an absolute sorting direction regardless of track placement sequence
	if pos_a.x > pos_b.x or (is_equal_approx(pos_a.x, pos_b.x) and pos_a.y > pos_b.y):
		var temp = pos_a
		pos_a = pos_b
		pos_b = temp

	var base_direction = (pos_b - pos_a).normalized()
	var perpendicular = Vector2(-base_direction.y, base_direction.x)
	# Distance spacing between parallel lines in pixels (Increase to 10.0 if tracks look too close)
	var track_spacing_pixels = 20.0

	return perpendicular * multiplier * track_spacing_pixels


# ---------------------------------------------------------------- score / game over

func _build_score_label() -> void:
	score_label = Label.new()
	score_label.text = "0"
	score_label.position = Vector2(16, 10)
	score_label.add_theme_font_size_override("font_size", 32)
	score_label.add_theme_color_override("font_color", Color("#2b2b2b"))
	hud.add_child(score_label)


## Called by trains via the "game" group.
func add_score(points: int = 1) -> void:
	if _game_over:
		return
	score += points
	score_label.text = str(score)


## Called by a station via the "game" group when its ring fills.
func on_station_overcrowded(_station: Area2D) -> void:
	if _game_over or _mode == SaveManager.Mode.ENDLESS:
		return  # Endless never ends
	_game_over = true
	_cancel_upgrade_drag()
	SaveManager.finish_run(_save_id, score)  # lost game: the save is deleted, the high score stays
	get_tree().paused = true
	_show_game_over()


func _show_game_over() -> void:
	var root := UIStyle.create_modal()
	var box: VBoxContainer = root.get_meta(&"box")

	box.add_child(UIStyle.label("Game over", 30))
	box.add_child(UIStyle.label("A station overcrowded", 16, Color(UIStyle.INK, 0.65)))

	# Score card, same look as the reward cards. "New best!" is gold, like the x2 badge.
	var new_best := score > _best_before
	var badge := UIStyle.badge(
		"New best!" if new_best else "Best %d" % SaveManager.get_high_score(_save_id),
		UIStyle.GOLD if new_best else UIStyle.BADGE_GREY)
	var card := UIStyle.make_card(Vector2(280, 0), 4)
	var body := UIStyle.card_body(card)
	body.add_child(UIStyle.card_header("", badge))
	body.add_child(UIStyle.label(str(score), 56))
	body.add_child(UIStyle.label("Passengers delivered", 15, Color(UIStyle.INK, 0.8)))
	box.add_child(card)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(row)

	var menu := UIStyle.button("Back to menu", &"secondary", Vector2(150, 48))
	menu.pressed.connect(func():
		get_tree().paused = false
		GameSession.return_home())
	row.add_child(menu)

	var again := UIStyle.button("Play again", &"primary", Vector2(150, 48))
	again.pressed.connect(func():
		get_tree().paused = false
		get_tree().reload_current_scene())
	row.add_child(again)

	hud.add_child(root)

func _on_upgrade_pressed(id: StringName) -> void:
	match id:
		&"line":
			_use_line_upgrade()
		&"station":
			_toggle_station_upgrade()
		


## Click the icon to arm the upgrade, click it again to cancel.
func _toggle_station_upgrade() -> void:
	if _station_upgrade_armed:
		_set_station_upgrade_armed(false)
		return
	if _game_over or _ghost != null or drag_mode != DragMode.NONE:
		return
	if upgrade_bar.get_count(&"station") <= 0:
		return
	_set_station_upgrade_armed(true)


func _set_station_upgrade_armed(armed: bool) -> void:
	_station_upgrade_armed = armed
	upgrade_bar.set_active(&"station", armed)


## Upgrades the station under the click. Clicking empty map (or an already
## upgraded station) does nothing and leaves the upgrade armed.
func _apply_station_upgrade(mouse_pos: Vector2) -> void:
	if _game_over or upgrade_bar.get_count(&"station") <= 0:
		_set_station_upgrade_armed(false)
		return
	var station := get_station_at_position(mouse_pos)
	if station == null or not station.apply_upgrade():
		return
	upgrade_bar.add_count(&"station", -1)
	_set_station_upgrade_armed(false)


## Highest number of lines this map allows (config cap, limited by the palette size).
func _max_line_count() -> int:
	return mini(config.max_lines, available_colors.size())


## Adds one more inactive line slot, using the next unused colour in the palette.
## Does nothing if no line upgrades are left or the map's max line count is reached.
func _use_line_upgrade() -> void:
	if _game_over:
		return
	if upgrade_bar.get_count(&"line") <= 0:
		return
	if slot_colors.size() >= _max_line_count():
		return
	var color: Color = available_colors[slot_colors.size()]
	slot_colors.append(color)
	line_bar.add_slot(color)
	upgrade_bar.add_count(&"line", -1)


# ---------------------------------------------------------------- upgrade drags

func _on_upgrade_grabbed(id: StringName) -> void:
	if id != &"station":
		_set_station_upgrade_armed(false)  # picking up another upgrade cancels the armed one
	match id:
		&"locomotive", &"carriage":
			_begin_upgrade_drag(id)


func _begin_upgrade_drag(id: StringName) -> void:
	if _game_over or _ghost != null or drag_mode != DragMode.NONE:
		return
	if upgrade_bar.get_count(id) <= 0:
		return
	_ghost_upgrade = id
	_ghost = LocomotiveGhost.new()
	if id == &"carriage":
		_ghost.size = Vector2(40,33)
	add_child(_ghost)
	_update_ghost()


# Per-frame so the snapped preview keeps tracking a moving train.
func _process(_delta: float) -> void:
	if _ghost != null:
		_update_ghost()


func _input(event: InputEvent) -> void:
	if _ghost == null or not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
		_drop_upgrade()  # not marked handled, so the button still sees the release
	elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		_cancel_upgrade_drag()


func _update_ghost() -> void:
	var mouse := get_global_mouse_position()
	var hit := _find_upgrade_target(mouse)
	if hit.is_empty():
		_ghost.show_free(mouse)
		_set_hovered_line(null)
		return
	var line: MetroLine = hit["line"]
	_ghost.show_snapped(hit["point"], hit["angle"], line.line_color)
	_set_hovered_line(line)


func _find_upgrade_target(pos: Vector2) -> Dictionary:
	match _ghost_upgrade:
		&"locomotive":
			return _find_line_for_locomotive(pos)
		&"carriage":
			return _find_train_for_carriage(pos)
	return {}


## Nearest line whose track is within the drop radius of `pos`, or {}.
func _find_line_for_locomotive(pos: Vector2) -> Dictionary:
	var best := {}
	var best_dist := INF
	for line in active_lines:
		var probe := line.probe_track(pos, locomotive_drop_radius)
		if probe.is_empty():
			continue
		var d := pos.distance_to(probe["point"])
		if d < best_dist:
			best_dist = d
			best = probe
			best["line"] = line
	return best


## Nearest train (with room for another carriage) within the drop radius, or {}.
func _find_train_for_carriage(pos: Vector2) -> Dictionary:
	var best := {}
	var best_dist := carriage_drop_radius
	for line in active_lines:
		for child in line.track_path.get_children():
			var train = child as Train
			if train == null or not train.can_add_carriage():
				continue
			var d := pos.distance_to(train.global_position)
			if d < best_dist:
				best_dist = d
				var pose := train.next_carriage_pose()
				best = {"line": line, "train": train, "point": pose["point"], "angle": pose["angle"]}
	return best


func _drop_upgrade() -> void:
	var id := _ghost_upgrade
	var hit := _find_upgrade_target(get_global_mouse_position())
	_cancel_upgrade_drag()
	if hit.is_empty():
		return  # released over nothing valid: no charge
	var line: MetroLine = hit["line"]
	match id:
		&"locomotive":
			line.spawn_train(hit["offset"])
		&"carriage":
			(hit["train"] as Train).add_carriage(line.line_color)
	upgrade_bar.add_count(id, -1)


func _cancel_upgrade_drag() -> void:
	if _ghost == null:
		return
	_ghost.queue_free()
	_ghost = null
	_ghost_upgrade = &""
	_set_hovered_line(null)
	_update_hover(get_global_mouse_position())


func bridges_remaining() -> int:
	var used := 0
	for line in active_lines:
		used += line.bridges_used
	return bridge_budget - used


func _refresh_bridges() -> void:
	upgrade_bar.set_count(&"bridge", bridges_remaining())

## GameClock emits this the instant Sunday ends.
func _on_week_started(weeks_completed: int) -> void:
	if _game_over or _reward_screen != null:
		return
	# Don't leave anything half-done behind the pause.
	_cancel_upgrade_drag()
	_set_station_upgrade_armed(false)
	if drag_mode != DragMode.NONE:
		_end_drag()   # commits the line being dragged, as if the mouse was released

	get_tree().paused = true
	_reward_screen = RewardScreen.new()
	hud.add_child(_reward_screen)
	_reward_screen.setup(upgrade_bar, weeks_completed)
	_reward_screen.reward_chosen.connect(_on_reward_chosen)


func _on_reward_chosen(id: StringName, amount: int) -> void:
	_reward_screen = null
	get_tree().paused = false
	if id == &"bridge":
		# The bridge count is derived (budget minus bridges in use), so raise the budget.
		bridge_budget += amount
		_refresh_bridges()
	else:
		upgrade_bar.add_count(id, amount)
	_save_game()  # the week-ending day is saved here, once the reward is in


# ---------------------------------------------------------------- menu button

#func _build_menu_button() -> void:
	#var button := Button.new()
	##button.text = "Menu"
	#button.custom_minimum_size = BUTTON_SIZE
	#button.focus_mode = Control.FOCUS_NONE
	#button.tooltip_text = "Back to the map list (progress is saved at the end of each day)"
	#button.pressed.connect(GameSession.return_home)
	#
	#var icon_rect := TextureRect.new()
	#icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	#icon_rect.texture = load("res://assets/icons/menu.svg")
	#icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	#icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	#icon_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 8)
	#button.add_child(icon_rect)
	#
	#
	#
	#hud.add_child(button)
	#button.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 24)
func _build_menu_button() -> void:
	var button := TextureButton.new()
	#button.text = "Menu"
	button.custom_minimum_size = BUTTON_SIZE
	button.focus_mode = Control.FOCUS_NONE
	button.ignore_texture_size = true
	button.stretch_mode =TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	button.tooltip_text = "Back to the map list (progress is saved at the end of each day)"
	button.texture_normal = load("res://assets/icons/menu.svg")
	button.pressed.connect(GameSession.return_home)
	
	hud.add_child(button)
	
	button.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	button.grow_vertical = Control.GROW_DIRECTION_BEGIN
	button.offset_left = 24.0
	button.offset_right = 24.0 + BUTTON_SIZE.x
	button.offset_top = -24.0 - BUTTON_SIZE.y
	button.offset_bottom = -24.0


# ---------------------------------------------------------------- save / resume

## Every day boundary autosaves. The one that ends a week is skipped here: the reward
## screen opens right after it, and _on_reward_chosen saves once the pick is made.
func _on_day_started(day: int) -> void:
	if day % GameClock.DAYS_PER_WEEK == 0:
		return
	_save_game()


func _save_game() -> void:
	if _game_over or not _loaded:
		return
	SaveManager.save_run(_save_id, _build_save(), _mode)


## Everything needed to rebuild the run. Only plain numbers / strings / arrays / dictionaries
## (it goes through JSON). Stations are referred to by their index in spawner.stations_grid.
func _build_save() -> Dictionary:
	var stations: Array = spawner.stations_grid.values()

	var spawner_data: Dictionary = spawner.get_save_data()
	var saved_stations: Array = spawner_data["stations"]
	for i in saved_stations.size():
		var waiting: Array = []
		for p in stations[i].waiting_passengers:
			waiting.append(_pack_passenger(p, stations))
		saved_stations[i]["waiting"] = waiting

	var lines: Array = []
	for line in active_lines:
		if line.distinct_station_count() < 2:
			continue  # a line with a single station isn't a line yet
		var route: Array = []
		for s in line.connected_stations:
			route.append(stations.find(s))  # loops repeat the first station at the end
		var trains: Array = []
		for child in line.track_path.get_children():
			var train := child as Train
			if train == null:
				continue
			var train_data := train.get_save_data()
			var riders: Array = []
			for p in train.onboard_passengers:
				riders.append(_pack_passenger(p, stations))
			train_data["riders"] = riders
			trains.append(train_data)
		lines.append({
			"color": available_colors.find(line.line_color),
			"stations": route,
			"loop": line.is_loop,
			"trains": trains,
		})

	# Upgrade counts belong to this run only. Bridges are derived (budget - in use).
	var upgrades := {}
	for id in config.get_starting_upgrade_counts().keys():
		if id != &"bridge":
			upgrades[String(id)] = upgrade_bar.get_count(id)

	return {
		"v": SaveManager.RUN_VERSION,
		"score": score,
		"day": GameClock.day,
		"day_progress": GameClock.day_progress,
		"slot_count": slot_colors.size(),
		"bridge_budget": bridge_budget,
		"upgrades": upgrades,
		"spawner": spawner_data,
		"director": director.get_save_data(),
		"lines": lines,
	}


## Stations, clock, upgrades and score are already back by the time this runs
## (_ready did those). This puts back passengers, lines, trains and the director.
func _restore_run(save: Dictionary) -> void:
	score = int(save.get("score", 0))
	score_label.text = str(score)

	var stations: Array = spawner.stations_grid.values()
	var saved_stations: Array = save.get("spawner", {}).get("stations", [])
	for i in mini(stations.size(), saved_stations.size()):
		var waiting: Array[Passenger] = []
		for pd in saved_stations[i].get("waiting", []):
			waiting.append(_unpack_passenger(pd, stations))
		stations[i].waiting_passengers = waiting
		stations[i].queue_redraw()

	# Lines first (all of them), trains second: a train's spot on its track shifts if
	# another line is added alongside it afterwards.
	var pending: Array = []  # [line, saved trains]
	for ld in save.get("lines", []):
		var route: Array[Area2D] = []
		for i in ld.get("stations", []):
			var idx := int(i)
			if idx >= 0 and idx < stations.size():
				route.append(stations[idx])
		var color_idx := int(ld.get("color", -1))
		if route.size() < 2 or color_idx < 0 or color_idx >= available_colors.size():
			continue
		var line: MetroLine = METRO_LINE_SCENE.instantiate()
		line.map = map
		line.route_changed.connect(_refresh_bridges)
		add_child(line)
		line.restore_line(route, available_colors[color_idx], bool(ld.get("loop", false)))
		active_lines.append(line)
		pending.append([line, ld.get("trains", [])])

	for entry in pending:
		var line: MetroLine = entry[0]
		for td in entry[1]:
			var train := line.spawn_train(float(td.get("progress", 0.0)))
			if train == null:
				continue
			train.apply_save_data(td)
			var riders: Array[Passenger] = []
			for pd in td.get("riders", []):
				riders.append(_unpack_passenger(pd, stations))
			train.set_onboard(riders)

	for line in active_lines:
		line.update_line_visuals()
	_refresh_line_bar()
	_refresh_bridges()

	director.apply_save_data(save.get("director", {}))


func _pack_passenger(p: Passenger, stations: Array) -> Dictionary:
	return {"t": p.target_type, "o": stations.find(p.origin_station)}


func _unpack_passenger(d: Dictionary, stations: Array) -> Passenger:
	var p := Passenger.new()
	p.target_type = str(d.get("t", ""))
	var o := int(d.get("o", -1))
	if o >= 0 and o < stations.size():
		p.origin_station = stations[o]
	return p
