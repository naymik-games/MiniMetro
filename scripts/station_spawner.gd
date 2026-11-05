# StationSpawner.gd
extends Node2D
@export var map: Node2D
const STATION = preload("uid://cfs58w7ivwk4p")

@export_group("Grid Configuration")
@export var cell_size: int = 32
@export var grid_width: int = 36
@export var grid_height: int = 20

@export_group("Map Configuration")
@export var map_image: Texture2D ## A small PNG (e.g., 36x20) where White = Land, Blue/Black = Water

var water_cells: Dictionary = {} # Vector2i -> bool

@export_group("Spawning Parameters")
@export var initial_station_count: int = 3
@export var spawn_interval: float = 15.0 
@export var minimum_station_distance_cells: int = 4 

@export var line_manager: Node2D 

var stations_grid: Dictionary = {}
var _spawn_accum: float = 0.0   # game seconds since the last station spawned
var _spawning: bool = false

@export_group("Shape Rules")
## Number of stations that must exist before each shape can appear (0 = from the start)
@export var unlock_at: Dictionary = {"circle": 0, "square": 0, "triangle": 0, "plus": 6, "hexagon":3,"star": 3}
## Relative likelihood once unlocked
@export var shape_weights: Dictionary = {"circle": 50, "square": 30, "triangle": 20, "plus": 6, "hexagon":3,"star": 3}
## Most spawns allowed to pass without this shape before it is forced (0 = no limit)
@export var max_gap: Dictionary = {"circle": 3, "square": 4, "triangle": 5, "plus": 15, "hexagon":15,"star": 20}

@export_group("Passenger Rules")
@export var passenger_weights: Dictionary = {"circle": 50, "square": 30, "triangle": 15, "plus": 5, "hexagon": 3, "star": 3}

var spawn_count: int = 0                 # stations successfully created so far
var last_spawn_index: Dictionary = {}    # shape -> spawn index it last appeared at

## `saved` is the "spawner" part of a save (empty = brand new game).
func start(p_map: Node2D, config: GameConfig, saved: Dictionary = {}) -> void:
	map = p_map
	initial_station_count = config.starting_stations
	_set_grid_from_map()  
	randomize()
	await _load_map()
	_spawning = true
	if saved.is_empty():
		for i in range(initial_station_count):
			spawn_random_station()
	else:
		_restore(saved)


func _set_grid_from_map() -> void:
	var px: Vector2 = map.get_map_pixel_size()
	grid_width = floori(px.x / cell_size)
	grid_height = floori(px.y / cell_size)

func _load_map() -> void:
	if map == null:
		return
	if not map.is_node_ready():
		await map.ready
	for x in grid_width:
		for y in grid_height:
			var cell := Vector2i(x, y)
			if not map.is_land(grid_to_world(cell)):
				water_cells[cell] = true

## Replaces the old Timer so station spawning follows the GameClock speed.
func _process(real_delta: float) -> void:
	if not _spawning or spawn_interval <= 0.0:
		return
	_spawn_accum += GameClock.scaled(real_delta)
	while _spawn_accum >= spawn_interval:
		_spawn_accum -= spawn_interval
		spawn_random_station()

func spawn_random_station() -> void:
	var max_attempts = 100
	var attempt = 0
	var chosen_grid_pos: Vector2i = Vector2i.ZERO
	var valid_position_found = false
	
	while attempt < max_attempts and not valid_position_found:
		attempt += 1
		var rx = randi_range(1, grid_width - 2)
		var ry = randi_range(1, grid_height - 2)
		var test_pos = Vector2i(rx, ry)

		if stations_grid.has(test_pos):
			continue
		if is_water_cell(test_pos): # <-- NEW: Prevent spawning on water
			continue
		if is_too_close_to_other_stations(test_pos):
			continue
		if is_cell_occupied_by_any_line(test_pos):
			continue
			
		chosen_grid_pos = test_pos
		valid_position_found = true
		
	if valid_position_found:
		instantiate_station_at_grid(chosen_grid_pos)
	else:
		print("Warning: Map is too crowded or blocked by lines! Failed to spawn station.")

func is_cell_occupied_by_any_line(test_grid_pos: Vector2i) -> bool:
	if not line_manager or not "active_lines" in line_manager:
		return false
	for line in line_manager.active_lines:
		var track_cells = line.get_occupied_grid_cells(cell_size)
		if test_grid_pos in track_cells:
			return true 
	return false

func is_too_close_to_other_stations(test_grid_pos: Vector2i) -> bool:
	for existing_grid_pos in stations_grid.keys():
		var distance = abs(test_grid_pos.x - existing_grid_pos.x) + abs(test_grid_pos.y - existing_grid_pos.y)
		if distance < minimum_station_distance_cells:
			return true
	return false


func _pick_shape() -> String:
	var available: Array[String] = []
	for shape in unlock_at:
		if spawn_count >= int(unlock_at[shape]):
			available.append(shape)

	# 1. Overdue shapes win. If several are overdue, the most overdue goes first.
	var overdue := ""
	var worst_excess := -1
	for shape in available:
		var gap: int = max_gap.get(shape, 0)
		if gap <= 0:
			continue
		var excess := _spawns_since(shape) - gap
		if excess >= 0 and excess > worst_excess:
			worst_excess = excess
			overdue = shape
	if overdue != "":
		return overdue

	# 2. Otherwise a normal weighted roll among unlocked shapes
	var total := 0
	for shape in available:
		total += int(shape_weights.get(shape, 0))
	if total <= 0:
		return available.front()
	var roll := randi_range(1, total)
	var running := 0
	for shape in available:
		running += int(shape_weights.get(shape, 0))
		if roll <= running:
			return shape
	return available.front()


## How many stations have spawned since this shape last did (or since it unlocked)
func _spawns_since(shape: String) -> int:
	var last: int = last_spawn_index.get(shape, int(unlock_at[shape]) - 1)
	return spawn_count - last - 1

func get_active_shapes() -> Array[String]:
	var result: Array[String] = []
	for station in stations_grid.values():
		if station.type not in result:
			result.append(station.type)
	return result

func instantiate_station_at_grid(grid_pos: Vector2i) -> void:
	var shape := _pick_shape()
	_create_station(grid_pos, shape)
	last_spawn_index[shape] = spawn_count
	spawn_count += 1
	print("Station successfully spawned at Grid coordinate: ", grid_pos)


func _create_station(grid_pos: Vector2i, shape: String) -> Area2D:
	var new_station = STATION.instantiate()
	add_child(new_station)
	if new_station.has_method("set_shape"):
		new_station.set_shape(shape)
	new_station.global_position = grid_to_world(grid_pos)
	stations_grid[grid_pos] = new_station
	new_station.add_to_group("stations")
	return new_station


# ------------------------------------------------------------------ saving

## Stations are listed in stations_grid order; game.gd relies on that order
## (lines and passengers refer to stations by index).
func get_save_data() -> Dictionary:
	var stations: Array = []
	for cell in stations_grid:
		var d: Dictionary = stations_grid[cell].get_save_data()
		d["cell"] = [cell.x, cell.y]
		stations.append(d)
	return {
		"spawn_count": spawn_count,
		"last_spawn_index": last_spawn_index.duplicate(),
		"spawn_accum": _spawn_accum,
		"stations": stations,
	}


func _restore(saved: Dictionary) -> void:
	spawn_count = int(saved.get("spawn_count", 0))
	_spawn_accum = float(saved.get("spawn_accum", 0.0))
	last_spawn_index.clear()
	var saved_last: Dictionary = saved.get("last_spawn_index", {})
	for shape in saved_last:
		last_spawn_index[str(shape)] = int(saved_last[shape])
	for entry in saved.get("stations", []):
		var cell := Vector2i(int(entry["cell"][0]), int(entry["cell"][1]))
		var station := _create_station(cell, str(entry.get("type", "circle")))
		station.apply_save_data(entry)


func grid_to_world(grid_pos: Vector2i):
	var pixel_x = (grid_pos.x * cell_size) + (cell_size / 2)
	var pixel_y = (grid_pos.y * cell_size) + (cell_size / 2)
	return Vector2(pixel_x, pixel_y)

func world_to_grid(pos: Vector2):
	Vector2i(floori(pos.x / cell_size), floori(pos.y / cell_size))


func _load_map_image() -> void:
	if not map_image:
		print("No map image provided. Entire grid treated as land.")
		return
		
	var img := map_image.get_image()
	if not img:
		return
		
	#img.lock()
	
	# Define your target water color: #5b7fa7
	var target_water_color := Color("#5b7fa7")
	
	for x in range(grid_width):
		for y in range(grid_height):
			# Map grid coordinate to image pixel coordinate (handles scaling if image is larger)
			var px = int(clamp(x * (img.get_width() / float(grid_width)), 0, img.get_width() - 1))
			var py = int(clamp(y * (img.get_height() / float(grid_height)), 0, img.get_height() - 1))
			var col := img.get_pixel(px, py)
			
			# Condition 1: Fully transparent pixels are land -> skip marking as water
			if is_zero_approx(col.a):
				continue
				
			# Condition 2: Check if color matches within a small tolerance across RGBA channels
			var r_diff = abs(col.r - target_water_color.r)
			var g_diff = abs(col.g - target_water_color.g)
			var b_diff = abs(col.b - target_water_color.b)
			
			if r_diff < 0.05 and g_diff < 0.05 and b_diff < 0.05:
				water_cells[Vector2i(x, y)] = true
				
	#img.unlock()
	print("Map loaded successfully. Total water cells: ", water_cells.size())
func is_water_cell(test_grid_pos: Vector2i) -> bool:
	return water_cells.has(test_grid_pos)



## Returns an array of water grid cells that a specific track segment passes through
func get_water_cells_along_segment(start_pixel: Vector2, end_pixel: Vector2) -> Array[Vector2i]:
	var crossing_water: Array[Vector2i] = []
	var sub_start = Vector2i(floori(start_pixel.x / cell_size), floori(start_pixel.y / cell_size))
	var sub_end = Vector2i(floori(end_pixel.x / cell_size), floori(end_pixel.y / cell_size))
	
	# Reuse standard grid rasterization logic
	var current = sub_start
	var delta = sub_end - sub_start
	var step_x = sign(delta.x)
	var step_y = sign(delta.y)
	var total_steps = max(abs(delta.x), abs(delta.y))
	
	if is_water_cell(current):
		crossing_water.append(current)
		
	for i in range(total_steps):
		current.x += step_x if delta.x != 0 else 0
		current.y += step_y if delta.y != 0 else 0
		if is_water_cell(current) and not current in crossing_water:
			crossing_water.append(current)
			
	return crossing_water


## Returns an array of unique water grid cells crossed between two world positions
func get_water_cells_along_path(start_pixel: Vector2, end_pixel: Vector2) -> Array[Vector2i]:
	var water_found: Array[Vector2i] = []
	
	# Replicate Mini Metro 45-degree / orthogonal path geometry steps
	var delta: Vector2 = end_pixel - start_pixel
	var abs_x: float = abs(delta.x)
	var abs_y: float = abs(delta.y)
	
	var points: Array[Vector2] = [start_pixel]
	if abs_x != 0 and abs_y != 0 and not is_equal_approx(abs_x, abs_y):
		var inflection_point: Vector2 = start_pixel
		if abs_x > abs_y:
			inflection_point.x += abs_y * sign(delta.x)
			inflection_point.y += abs_y * sign(delta.y)
		else:
			inflection_point.x += abs_x * sign(delta.x)
			inflection_point.y += abs_x * sign(delta.y)
		points.append(inflection_point)
	points.append(end_pixel)
	
	# Rasterize segments and check against water_cells dictionary
	for i in range(points.size() - 1):
		var sub_start = Vector2i(floori(points[i].x / cell_size), floori(points[i].y / cell_size))
		var sub_end = Vector2i(floori(points[i + 1].x / cell_size), floori(points[i + 1].y / cell_size))
		
		var current = sub_start
		var line_delta = sub_end - sub_start
		var step_x = sign(line_delta.x)
		var step_y = sign(line_delta.y)
		
		if water_cells.has(current) and not current in water_found:
			water_found.append(current)
			
		var total_steps = max(abs(line_delta.x), abs(line_delta.y))
		for step in range(total_steps):
			current.x += step_x if line_delta.x != 0 else 0
			current.y += step_y if line_delta.y != 0 else 0
			if water_cells.has(current) and not current in water_found:
				water_found.append(current)
				
	return water_found
