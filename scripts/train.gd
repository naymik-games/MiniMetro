# Train.gd
class_name Train
extends PathFollow2D

@export var speed: float = 150.0
@export var station_wait_time: float = 1.0 # Time to pause at a station in seconds
@export var capacity: int = 6

@export var carriage_capacity: int = 6    ## extra passenger slots per carriage
@export var max_carriages: int = 2
@export var carriage_gap: float = 45.0    ## px between train/carriage centres along the track
@export var carriage_swing_speed: float = 4.0  ## how fast carriages swing to the other side on a turnaround

var carriages: Array[TrainCarriage] = []
var _trail_side: float = 1.0

var direction: int = 1 # 1 = forward, -1 = backward
var is_running: bool = true
var is_on_looping_line: bool = false

## Distance along the track at which each station sits. Pushed in by MetroLine
## whenever the route changes, so editing a line can never desync the train.
var station_offsets: PackedFloat32Array = PackedFloat32Array()
var wait_time_left: float = 0.0
var onboard_passengers: Array[Passenger] = []

## The locomotive body, drawn in code. Set the line colour through `color`
## (don't use modulate: it would also tint the windows and rider icons).
var loco: TrainCar
var color: Color = Color.WHITE:
	set(value):
		color = value
		if loco:
			loco.color = value

func _ready() -> void:
	loop = false # we handle the ends ourselves (reverse or wrap)
	loco = TrainCar.new()
	loco.is_locomotive = true
	loco.color = color
	loco.configure(capacity, 3)  # 12 slots -> 4 columns x 3 rows
	add_child(loco)  # carriages are moved to index 0, so they draw underneath

## Called by MetroLine after the route changed (or when the train is first spawned).
func on_route_changed(offsets: PackedFloat32Array, new_progress: float, is_loop: bool) -> void:
	station_offsets = offsets
	is_on_looping_line = is_loop
	if is_loop:
		direction = 1
	progress = new_progress



func _process(real_delta: float) -> void:
	var delta := GameClock.scaled(real_delta)  # 0 when paused, 20x on ULTRA
	_advance(delta)
	_update_carriages(delta)


func _advance(delta: float) -> void:
	if not is_running or station_offsets.is_empty():
		return

	if wait_time_left > 0.0:
		wait_time_left -= delta
		if wait_time_left <= 0.0:
			_leave_station()
		return

	var length := _track_length()
	if length <= 0.0:
		return

	var old_progress := progress
	var new_progress := old_progress + speed * direction * delta

	var stop_index := _find_stop_between(old_progress, new_progress, length)
	if stop_index >= 0:
		progress = minf(station_offsets[stop_index], length)
		var line := get_parent().get_parent() as MetroLine
		var stop_station: Area2D = null
		if line and stop_index < line.connected_stations.size():
			stop_station = line.connected_stations[stop_index]
		# Upgraded stations shorten the stop
		var stop_multiplier := 1.0
		if stop_station:
			stop_multiplier = stop_station.get_stop_time_multiplier()
		wait_time_left = station_wait_time * stop_multiplier
		if stop_station:
			_handle_station_arrival(stop_station, line, stop_index)
		return

	progress = clampf(new_progress, 0.0, length)
	if (direction == 1 and progress >= length) or (direction == -1 and progress <= 0.0):
		_turn_around(length)



## Index into station_offsets of the nearest station we pass going from -> to, or -1.
func _find_stop_between(from_offset: float, to_offset: float, length: float) -> int:
	var best := -1
	var best_offset := 0.0
	for i in station_offsets.size():
		var s := minf(station_offsets[i], length)
		if direction == 1 and s > from_offset and s <= to_offset:
			if best < 0 or s < best_offset:
				best = i
				best_offset = s
		elif direction == -1 and s < from_offset and s >= to_offset:
			if best < 0 or s > best_offset:
				best = i
				best_offset = s
	return best


func _leave_station() -> void:
	var length := _track_length()
	if direction == 1 and progress >= length - 0.01:
		_turn_around(length)
	elif direction == -1 and progress <= 0.01:
		_turn_around(length)


func _turn_around(length: float) -> void:
	if is_on_looping_line:
		# First and last station are the same spot, so just wrap
		progress = 0.0 if direction == 1 else length
	else:
		direction *= -1


func _track_length() -> float:
	var path := get_parent() as Path2D
	if path == null or path.curve == null:
		return 0.0
	return path.curve.get_baked_length()
# Inside Train.gd


func _handle_station_arrival(station: Area2D, line: MetroLine, stop_index: int) -> void:
	var router := TransitRouter.new(get_tree())
	var next_station := _next_station(stop_index, line)

	# 1. Alight: deliver matches. Stay aboard only if the best route continues on
	#    this line AND this train is heading the right way; otherwise get off.
	var still_aboard: Array[Passenger] = []
	var exiting: Array[Passenger] = []
	for p in onboard_passengers:
		if p.target_type == station.type:
			_deliver_passenger(p)
			continue
		var route := router.plan(station, p.target_type, line)
		if _route_fits(route, line, next_station):
			still_aboard.append(p)
		else:
			exiting.append(p)
	onboard_passengers = still_aboard

	# 2. Board: only passengers whose route starts with this line AND this direction.
	#    Passengers who just got off are held back so they can't hop straight back on.
	var still_waiting: Array[Passenger] = []
	var was_full := false
	for p in station.waiting_passengers:
		var route := router.plan(station, p.target_type)
		var wants_this_train := _route_fits(route, line, next_station)
		if wants_this_train and onboard_passengers.size() < capacity:
			onboard_passengers.append(p)
		else:
			if wants_this_train:
				was_full = true
			still_waiting.append(p)

	if was_full:
		print("Train at capacity")
	still_waiting.append_array(exiting)
	station.waiting_passengers = still_waiting
	station.queue_redraw()
	_update_rider_icons()


func _route_fits(route: Dictionary, line: MetroLine, next_station: Area2D) -> bool:
	return not route.is_empty() and route["line"] == line and route["next"] == next_station


## The station this train will head for when it leaves `stop_index`.
## At the end of an open line it turns around, so the answer flips there.
func _next_station(stop_index: int, line: MetroLine) -> Area2D:
	var stations := line.connected_stations
	var last := stations.size() - 1
	var step := direction
	if is_on_looping_line:
		step = 1
	elif stop_index <= 0:
		step = 1
	elif stop_index >= last:
		step = -1

	var i := stop_index + step
	if is_on_looping_line:
		# stations[0] and stations[last] are the same stop, so wrap past the duplicate
		if i > last:
			i = 1
		elif i < 0:
			i = last - 1
	if i < 0 or i > last:
		return null
	return stations[i]

func _deliver_passenger(p: Passenger) -> void:
	get_tree().call_group("game", "add_score", 1)
	_update_rider_icons()

## Hands every rider back to the nearest of `stations` (used when the line is deleted).
func release_passengers(stations: Array[Area2D]) -> void:
	if onboard_passengers.is_empty():
		return

	var nearest: Area2D = null
	var best := INF
	for s in stations:
		if not is_instance_valid(s):
			continue
		var d := global_position.distance_squared_to(s.global_position)
		if d < best:
			best = d
			nearest = s

	if nearest != null:
		nearest.waiting_passengers.append_array(onboard_passengers)
		nearest.queue_redraw()
	onboard_passengers.clear()
	_update_rider_icons()

## Hands each vehicle its own slice of the riders: locomotive first, then each carriage.
func _update_rider_icons() -> void:
	if loco == null:
		return
	var types := PackedStringArray()
	for p in onboard_passengers:
		types.append(p.target_type)

	var loco_slots := capacity - carriages.size() * carriage_capacity
	loco.set_riders(types.slice(0, loco_slots))
	var start := loco_slots
	for c in carriages:
		c.set_riders(types.slice(start, start + carriage_capacity))
		start += carriage_capacity


# ------------------------------------------------------------------ saving

func get_save_data() -> Dictionary:
	return {
		"progress": progress,
		"direction": direction,
		"wait": wait_time_left,
		"carriages": carriages.size(),
	}


## Call after the train sits on its (restored) line. Riders are set separately via set_onboard().
func apply_save_data(d: Dictionary) -> void:
	if not is_on_looping_line:
		direction = -1 if int(d.get("direction", 1)) < 0 else 1
	_trail_side = float(direction)
	wait_time_left = float(d.get("wait", 0.0))
	for _i in int(d.get("carriages", 0)):
		add_carriage(color)


func set_onboard(passengers: Array[Passenger]) -> void:
	onboard_passengers = passengers
	_update_rider_icons()


func can_add_carriage() -> bool:
	return carriages.size() < max_carriages


func add_carriage(car_color: Color) -> void:
	if not can_add_carriage():
		return
	var carriage := TrainCarriage.new()
	carriage.color = car_color
	carriage.configure(carriage_capacity, 3)  # 6 slots -> 3 columns x 2 rows
	add_child(carriage)
	move_child(carriage, 0)  # draw underneath the sprite and rider icons
	carriages.append(carriage)
	capacity += carriage_capacity
	_update_carriages(0.0)
	_update_rider_icons()


## Where the next carriage would sit (used for the drag preview).
func next_carriage_pose() -> Dictionary:
	return _pose_behind(carriage_gap * (carriages.size() + 1))


func _update_carriages(delta: float) -> void:
	# Glide the trailing side around instead of teleporting when the train reverses.
	_trail_side = move_toward(_trail_side, float(direction), carriage_swing_speed * delta)
	for i in carriages.size():
		var pose := _pose_behind(carriage_gap * (i + 1))
		carriages[i].global_position = pose["point"]
		carriages[i].global_rotation = pose["angle"]


func _pose_behind(distance: float) -> Dictionary:
	var fallback := {"point": global_position, "angle": global_rotation}
	var path := get_parent() as Path2D
	if path == null or path.curve == null or path.curve.point_count < 2:
		return fallback
	var curve := path.curve
	var length := curve.get_baked_length()
	if length <= 0.0:
		return fallback
	var o := progress - distance * _trail_side
	if is_on_looping_line:
		o = fposmod(o, length)
	var co := clampf(o, 0.0, length)
	var a := curve.sample_baked(clampf(co - 2.0, 0.0, length))
	var b := curve.sample_baked(clampf(co + 2.0, 0.0, length))
	var tangent := (b - a).normalized()
	if tangent == Vector2.ZERO:
		tangent = Vector2.RIGHT
	# Past either end of an open line the carriage overhangs along the end tangent.
	var local_pos := curve.sample_baked(co) + tangent * (o - co)
	return {
		"point": path.to_global(local_pos),
		"angle": path.global_transform.basis_xform(tangent).angle(),
	}
