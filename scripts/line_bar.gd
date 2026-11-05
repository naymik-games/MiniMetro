# line_bar.gd
class_name LineBar
extends VBoxContainer
## Vertical bar on the right edge of the screen, one tab per available line.
## A tab is short while its line is free and grows once the line is in use.
## Created from code by game.gd and added to the HUD CanvasLayer.

@export var idle_width: float = 24.0
@export var active_width: float = 40.0
@export var slot_height: float = 20.0
@export var slot_spacing: int = 14
@export_range(0.0, 1.0) var idle_alpha: float = 0.55
@export var anim_time: float = 0.18

var _slots: Array[Panel] = []
var _colors: Array[Color] = []
var _active: Array[bool] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE  # never block clicks on the map

	# Pin to the vertical centre of the right edge. Fixed width so the bar
	# doesn't jump around while tabs animate; height follows the tabs.
	custom_minimum_size.x = active_width
	set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT, Control.PRESET_MODE_MINSIZE)
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	grow_vertical = Control.GROW_DIRECTION_BOTH


## Builds one tab per colour, in order from top to bottom.
func setup(colors: Array[Color]) -> void:
	for child in get_children():
		child.queue_free()
	_slots.clear()
	_active.clear()
	_colors = colors.duplicate()

	add_theme_constant_override("separation", slot_spacing)

	for color in _colors:
		_add_slot_node(color, false)


## Appends one more (inactive) tab at the bottom of the bar.
func add_slot(color: Color) -> void:
	_colors.append(color)
	_add_slot_node(color, true)


func _add_slot_node(color: Color, fade_in: bool) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	# Rounded on the inner (left) side only; the right side sits flush on the screen edge.
	style.corner_radius_top_left = int(slot_height / 2.0)
	style.corner_radius_bottom_left = int(slot_height / 2.0)

	var slot := Panel.new()
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.custom_minimum_size = Vector2(idle_width, slot_height)
	slot.size_flags_horizontal = Control.SIZE_SHRINK_END  # anchor to the right edge
	slot.add_theme_stylebox_override("panel", style)
	add_child(slot)

	_slots.append(slot)
	_active.append(false)

	if fade_in:
		slot.modulate.a = 0.0
		slot.create_tween().tween_property(slot, "modulate:a", idle_alpha, anim_time)
	else:
		slot.modulate.a = idle_alpha


## Tell the bar which colours are currently in use; only changed tabs animate.
func refresh(used_colors: Array[Color]) -> void:
	for i in _slots.size():
		var in_use: bool = _colors[i] in used_colors
		if in_use == _active[i]:
			continue
		_active[i] = in_use
		_animate(_slots[i], in_use)


func _animate(slot: Panel, in_use: bool) -> void:
	var tween := slot.create_tween()
	tween.set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(slot, "custom_minimum_size:x", active_width if in_use else idle_width, anim_time)
	tween.tween_property(slot, "modulate:a", 1.0 if in_use else idle_alpha, anim_time)
