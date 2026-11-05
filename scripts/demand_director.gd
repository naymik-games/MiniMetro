# demand_director.gd
class_name DemandDirector
extends Node
## Owns the difficulty curve (passenger spawn rate that grows over time) and
## "special events" (temporary demand spikes toward plus / hexagon / star stations).
## Created from game.gd in code, so there's nothing to add to the scene.

## Shapes that can host an event. Needs at least one station of that shape on the map.
const EVENT_SHAPES: Array[String] = ["plus", "hexagon", "star"]
## +15% passenger rate per minute (before aggression is applied)...
const RATE_GROWTH_PER_MINUTE: float = 0.15
## ...but never more than this multiple of the base rate.
const RATE_CAP: float = 3.0

var config: GameConfig
var spawner: Node2D
var hud: CanvasLayer

var elapsed: float = 0.0  # game seconds (follows GameClock speed)

# --- event state ---
var event_shape: String = ""        # "" = no event running
var _event_time_left: float = 0.0
var _next_event_in: float = 0.0

# --- banner ---
var _banner: PanelContainer
var _banner_icon: TextureRect
var _banner_label: Label
var _banner_tween: Tween


func setup(p_config: GameConfig, p_spawner: Node2D, p_hud: CanvasLayer) -> void:
	config = p_config
	spawner = p_spawner
	hud = p_hud
	add_to_group("demand_director")
	_next_event_in = config.first_event_delay
	_build_banner()


func _process(real_delta: float) -> void:
	var delta := GameClock.scaled(real_delta)
	elapsed += delta
	if config == null or not config.demand_events_enabled:
		return

	if event_shape != "":
		_event_time_left -= delta
		_update_banner_text()
		if _event_time_left <= 0.0:
			_end_event()
	else:
		_next_event_in -= delta
		if _next_event_in <= 0.0:
			_try_start_event()


# ------------------------------------------------------------------- saving

func get_save_data() -> Dictionary:
	return {
		"elapsed": elapsed,
		"event_shape": event_shape,
		"event_time_left": _event_time_left,
		"next_event_in": _next_event_in,
	}


## Call after setup() and after the stations exist (the venue highlight and banner need them).
func apply_save_data(d: Dictionary) -> void:
	if d.is_empty():
		return
	elapsed = float(d.get("elapsed", 0.0))
	_next_event_in = float(d.get("next_event_in", _next_event_in))
	var shape := str(d.get("event_shape", ""))
	if shape != "" and config.demand_events_enabled:
		event_shape = shape
		_event_time_left = float(d.get("event_time_left", config.event_duration))
		_set_venue_highlight(shape, true)
		_show_banner(shape)


# ------------------------------------------------------------------ queries
# Stations call these.

## Growth curve: 1.0 at the start, rising linearly, capped at RATE_CAP.
func get_growth_multiplier() -> float:
	var minutes := elapsed / 60.0
	return minf(RATE_CAP, 1.0 + minutes * RATE_GROWTH_PER_MINUTE * config.passenger_spawn_aggression)


## How fast `station` should be producing passengers right now (1.0 = base interval).
func get_spawn_rate(station: Area2D) -> float:
	var rate := get_growth_multiplier()
	# During an event everyone EXCEPT the venue itself sends more people toward it.
	if event_shape != "" and station.type != event_shape:
		rate *= config.event_rate_boost
	return rate


## Multiplier on how likely a passenger is to pick `shape` as its destination.
func get_target_weight_multiplier(shape: String) -> float:
	if event_shape != "" and shape == event_shape:
		return config.event_demand_boost
	return 1.0


# ------------------------------------------------------------------- events

func _try_start_event() -> void:
	var active: Array[String] = spawner.get_active_shapes()
	var candidates: Array[String] = []
	for shape in EVENT_SHAPES:
		# Need a venue AND some other station type to send people to it
		if shape in active and active.size() > 1:
			candidates.append(shape)

	if candidates.is_empty():
		_next_event_in = 10.0  # nothing eligible yet, look again shortly
		return

	_start_event(candidates.pick_random())


func _start_event(shape: String) -> void:
	event_shape = shape
	_event_time_left = config.event_duration
	_set_venue_highlight(shape, true)
	_show_banner(shape)


func _end_event() -> void:
	_set_venue_highlight(event_shape, false)
	event_shape = ""
	_hide_banner()
	_next_event_in = randf_range(config.event_gap_min, config.event_gap_max)


func _set_venue_highlight(shape: String, on: bool) -> void:
	for station in get_tree().get_nodes_in_group("stations"):
		if station.type == shape:
			station.set_event_venue(on)


# ------------------------------------------------------------------- banner

func _build_banner() -> void:
	_banner = PanelContainer.new()
	_banner.visible = false
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, 12)
	_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_banner.add_child(row)

	_banner_icon = TextureRect.new()
	_banner_icon.custom_minimum_size = Vector2(22, 22)
	_banner_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_banner_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(_banner_icon)

	_banner_label = Label.new()
	_banner_label.add_theme_font_size_override("font_size", 20)
	row.add_child(_banner_label)

	hud.add_child(_banner)


func _show_banner(shape: String) -> void:
	_banner_icon.texture = _texture_for(shape)
	_update_banner_text()
	_banner.visible = true
	_banner.modulate.a = 0.0
	if _banner_tween:
		_banner_tween.kill()
	_banner_tween = create_tween()
	_banner_tween.tween_property(_banner, "modulate:a", 1.0, 0.4)


func _hide_banner() -> void:
	if _banner_tween:
		_banner_tween.kill()
	_banner_tween = create_tween()
	_banner_tween.tween_property(_banner, "modulate:a", 0.0, 0.4)
	_banner_tween.tween_callback(func(): _banner.visible = false)


func _update_banner_text() -> void:
	var secs := maxi(0, ceili(_event_time_left))
	_banner_label.text = "Special event at %s  ·  %d:%02d" % [event_shape.capitalize(), secs / 60, secs % 60]


func _texture_for(shape: String) -> Texture:
	for station in get_tree().get_nodes_in_group("stations"):
		if station.type == shape:
			return station.sprite_2d.texture
	return null
