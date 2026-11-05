extends Area2D
@export var circle_texture: Texture
@export var square_texture: Texture
@export var triangle_texture: Texture
@export var plus_texture: Texture
@export var hexagon_texture: Texture
@export var star_texture: Texture
@export var octogon_texture: Texture

@export_group("Overcrowding")
## Waiting passengers a station can hold before it starts to overcrowd
@export var max_waiting: int = 6
## Seconds an overcrowded station takes to fill its ring (then it's game over)
@export var overcrowd_seconds: float = 25.0
## How much faster the ring drains once the queue is back under the limit
@export var recover_speed: float = 2.0
@export var ring_radius: float = 24.0
@export var ring_color: Color = Color("#e5342b")

@export_group("Upgrade")
## Sprite (and ring / queue icon) size multiplier once upgraded.
@export var upgraded_scale: float = 1.2
## Extra waiting passengers an upgraded station can hold before it overcrowds.
@export var upgrade_extra_waiting: int = 4
## Multiplier on the time a train stops here once upgraded (lower = faster).
@export var upgrade_stop_time_multiplier: float = 0.5

@export_group("Special events")
@export var event_ring_color: Color = Color("#f5a623")
@export var event_ring_radius: float = 30.0

@onready var sprite_2d: Sprite2D = $Sprite2D
var waiting_passengers: Array[Passenger] = []
var type: String
## Seconds between passengers at the base rate. The director speeds this up.
var spawn_interval: float = 8.0
var _spawn_progress: float = 0.0   # seconds of "spawn time" banked so far
var overcrowd_progress: float = 0.0  # 0..1
var _failed: bool = false
var _is_event_venue: bool = false
var _director: DemandDirector
var upgraded: bool = false
var _base_sprite_scale: Vector2 = Vector2.ONE


func _ready() -> void:
	_base_sprite_scale = sprite_2d.scale
	_director = get_tree().get_first_node_in_group("demand_director") as DemandDirector


func _process(real_delta: float) -> void:
	if _failed:
		return

	var delta := GameClock.scaled(real_delta)  # game time: spawning and overcrowding follow the clock
	_tick_spawning(delta)

	var needs_redraw := _is_event_venue  # pulsing ring animates every frame
	if waiting_passengers.size() > get_max_waiting():
		overcrowd_progress += delta / overcrowd_seconds
		needs_redraw = true
	elif overcrowd_progress > 0.0:
		overcrowd_progress = maxf(0.0, overcrowd_progress - delta * recover_speed / overcrowd_seconds)
		needs_redraw = true

	if needs_redraw:
		queue_redraw()
	if overcrowd_progress >= 1.0:
		_failed = true
		get_tree().call_group("game", "on_station_overcrowded", self)


# ------------------------------------------------------------------ spawning

## Instead of a fixed Timer, bank time scaled by the current rate. A rate of 2.0
## fills the bar twice as fast, and rate changes (growth, events) apply instantly.
func _tick_spawning(delta: float) -> void:
	var rate := _director.get_spawn_rate(self) if _director else 1.0
	_spawn_progress += delta * rate
	if _spawn_progress >= spawn_interval:
		_spawn_progress -= spawn_interval
		spawn_passenger(type)


func spawn_passenger(host_station_type: String) -> void:
	# Available types excluding host station's type
	var pool: Array = get_parent().get_active_shapes()
	pool.erase(host_station_type)
	if pool.is_empty():
		return

	var passenger := Passenger.new()
	passenger.target_type = _get_weighted_random_shape(pool)
	passenger.origin_station = self

	waiting_passengers.append(passenger)
	queue_redraw() # Update UI icons waiting next to station


func _get_weighted_random_shape(allowed_shapes: Array) -> String:
	var base_weights: Dictionary = get_parent().passenger_weights
	var weights := {}
	var total_weight := 0.0
	for shape in allowed_shapes:
		var w: float = float(base_weights.get(shape, 0))
		if _director:
			w *= _director.get_target_weight_multiplier(shape)
		weights[shape] = w
		total_weight += w

	if total_weight <= 0.0:
		return allowed_shapes.pick_random()

	var roll := randf() * total_weight
	var running := 0.0
	for shape in allowed_shapes:
		running += weights[shape]
		if roll <= running:
			return shape
	return allowed_shapes.back()


# ------------------------------------------------------------------- upgrade

func get_max_waiting() -> int:
	return max_waiting + (upgrade_extra_waiting if upgraded else 0)


## Multiplier a train applies to its normal stop time here.
func get_stop_time_multiplier() -> float:
	return upgrade_stop_time_multiplier if upgraded else 1.0


func _visual_scale() -> float:
	return upgraded_scale if upgraded else 1.0


## Returns false if the station was already upgraded.
func apply_upgrade() -> bool:
	if upgraded:
		return false
	upgraded = true
	var tween := create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(sprite_2d, "scale", _base_sprite_scale * upgraded_scale, 0.2)
	queue_redraw()
	return true


# -------------------------------------------------------------------- events

func set_event_venue(on: bool) -> void:
	_is_event_venue = on
	queue_redraw()


# ------------------------------------------------------------------- saving

## Waiting passengers are saved by game.gd (they need station indices).
func get_save_data() -> Dictionary:
	return {
		"type": type,
		"upgraded": upgraded,
		"spawn_progress": _spawn_progress,
		"overcrowd": overcrowd_progress,
	}


## Call after the station is in the tree and its shape is set.
func apply_save_data(d: Dictionary) -> void:
	_spawn_progress = float(d.get("spawn_progress", 0.0))
	overcrowd_progress = clampf(float(d.get("overcrowd", 0.0)), 0.0, 0.99)
	if d.get("upgraded", false):
		upgraded = true
		sprite_2d.scale = _base_sprite_scale * upgraded_scale
	queue_redraw()


# --------------------------------------------------------------------- shape

func set_shape(shape: String):
	type = shape
	sprite_2d.texture = _get_texture_for_type(shape)


func _get_texture_for_type(shape_type: String) -> Texture:
	match shape_type:
		"circle":
			return circle_texture
		"square":
			return square_texture
		"triangle":
			return triangle_texture
		"plus":
			return plus_texture
		"hexagon":
			return hexagon_texture
		"star":
			return star_texture
	return null


# ---------------------------------------------------------------------- draw

func _draw() -> void:
	if _is_event_venue:
		var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() / 1000.0 * TAU * 0.8)
		var col := event_ring_color
		col.a = lerpf(0.35, 1.0, pulse)
		draw_arc(Vector2.ZERO, event_ring_radius * _visual_scale() + pulse * 3.0, 0.0, TAU, 48, col, 3.0, true)

	if overcrowd_progress > 0.0:
		draw_arc(Vector2.ZERO, ring_radius * _visual_scale(), -PI / 2.0, -PI / 2.0 + TAU * overcrowd_progress, 48, ring_color, 4.0, true)
	if waiting_passengers.is_empty():
		return

	var icon_size := 10.0
	var spacing := 12.0
	var start_offset := Vector2(20 * _visual_scale(), -20) # Positioned to the right of the station sprite

	# Show up to the station's limit; anything beyond it (overcrowding) shows as "+"
	var visible_cap := get_max_waiting()
	var max_visible = min(waiting_passengers.size(), visible_cap)

	for i in range(max_visible):
		var passenger = waiting_passengers[i]
		var tex = _get_texture_for_type(passenger.target_type)
		if tex:
			var pos = start_offset + Vector2(i * spacing, 0)
			draw_texture_rect(tex, Rect2(pos, Vector2(icon_size, icon_size)), false)

	if waiting_passengers.size() > visible_cap:
		var overflow_pos = start_offset + Vector2(max_visible * spacing, -2)
		draw_string(ThemeDB.fallback_font, overflow_pos, "+", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
