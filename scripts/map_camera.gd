class_name MapCamera
extends Camera2D
## Fits the map between the HUD bars, then lets the player pan (drag on empty map)
## and zoom (pinch / mouse wheel / trackpad), always clamped to the map.
##
## Zoom range:
##   zoom-out limit = max(fit_zoom, min_zoom_floor)   -> never shrinks below 0.8
##   zoom-in limit  = max_zoom
## If the map doesn't fit at the zoom-out limit, the extra is reached by panning.
##
## All screen positions here are viewport units (after canvas_items stretch).

## The player started a two-finger gesture; cancel any in-progress line drag.
signal pinch_started

@export_group("HUD margins (screen space)")
@export var margin_left := 80.0      # upgrade bar
@export var margin_right := 32.0     # line bar
@export var margin_top := 0.0
@export var margin_bottom := 0.0

@export_group("Zoom / pan")
@export var min_zoom_floor := 0.8    # farthest the camera may zoom out
@export var max_zoom := 2.0
@export var wheel_step := 1.1
@export var pan_margin := 48.0       # world units you may pan past the map edge
@export var pan_start_distance := 8.0  # px a press must travel before it pans

var _world := Vector2(1280, 640)     # playable size in world units
var _zoom := 1.0
var _min_zoom := 1.0
var _max_zoom := 2.0
var _focus := Vector2.ZERO           # world point at the centre of the free (non-HUD) area
var _free_size := Vector2.ZERO
var _free_center := Vector2.ZERO     # screen-space centre of the free area

var _panning := false
var _pan_active := false
var _pan_start := Vector2.ZERO
var _pan_last := Vector2.ZERO

var _touches := {}                   # touch index -> screen position
var _pinching := false
var _pinch_ids: Array = []
var _prev_mid := Vector2.ZERO
var _prev_dist := 0.0


func setup(world_size: Vector2) -> void:
	_world = world_size
	anchor_mode = Camera2D.ANCHOR_MODE_DRAG_CENTER   # position = world point at screen centre
	if not get_viewport().size_changed.is_connected(_on_viewport_resized):
		get_viewport().size_changed.connect(_on_viewport_resized)
	_recompute(true)


func is_panning() -> bool:
	return _panning


func is_pinching() -> bool:
	return _pinching


# ---------------------------------------------------------------- pan (driven by game.gd)

func begin_pan(screen_pos: Vector2) -> void:
	if _pinching:
		return
	_panning = true
	_pan_active = false
	_pan_start = screen_pos
	_pan_last = screen_pos


func pan_move(screen_pos: Vector2) -> void:
	if not _panning:
		return
	if not _pan_active:
		if screen_pos.distance_to(_pan_start) < pan_start_distance:
			return   # still a tap, don't jitter the view
		_pan_active = true
		_pan_last = screen_pos
		return
	var delta := screen_pos - _pan_last
	_pan_last = screen_pos
	_focus -= delta / _zoom
	_apply()


func end_pan() -> void:
	_panning = false
	_pan_active = false


# ---------------------------------------------------------------- zoom + pinch (self-driven)

func _input(event: InputEvent) -> void:
	# _input (not unhandled) so a finger that lands on the HUD still counts for pinching.
	# We never mark these handled, so the HUD and the emulated mouse still work.
	if event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			_touches[st.index] = st.position
			if _touches.size() >= 2 and not _pinching:
				_start_pinch()
		else:
			_touches.erase(st.index)
			if _pinching and not (_touches.has(_pinch_ids[0]) and _touches.has(_pinch_ids[1])):
				_pinching = false
	elif event is InputEventScreenDrag:
		var sd := event as InputEventScreenDrag
		if _touches.has(sd.index):
			_touches[sd.index] = sd.position
			if _pinching:
				_update_pinch()


func _unhandled_input(event: InputEvent) -> void:
	# Desktop / trackpad zoom
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				_zoom_about(mb.position, mb.position, wheel_step)
			elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_zoom_about(mb.position, mb.position, 1.0 / wheel_step)
	elif event is InputEventMagnifyGesture:
		var mg := event as InputEventMagnifyGesture
		_zoom_about(mg.position, mg.position, mg.factor)


func _notification(what: int) -> void:
	# Don't get stuck "pinching" if the app loses focus mid-gesture
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_touches.clear()
		_pinching = false
		end_pan()


func _start_pinch() -> void:
	var keys := _touches.keys()
	_pinch_ids = [keys[0], keys[1]]
	_pinching = true
	end_pan()   # the two-finger gesture takes over from a one-finger pan
	var a: Vector2 = _touches[_pinch_ids[0]]
	var b: Vector2 = _touches[_pinch_ids[1]]
	_prev_mid = (a + b) * 0.5
	_prev_dist = a.distance_to(b)
	pinch_started.emit()


func _update_pinch() -> void:
	var a: Vector2 = _touches[_pinch_ids[0]]
	var b: Vector2 = _touches[_pinch_ids[1]]
	var mid := (a + b) * 0.5
	var dist := a.distance_to(b)
	var factor := dist / _prev_dist if _prev_dist > 1.0 else 1.0
	# The world point under the old midpoint ends up under the new midpoint:
	# that gives zoom-about-fingers and two-finger pan in one step.
	_zoom_about(_prev_mid, mid, factor)
	_prev_mid = mid
	_prev_dist = dist


## Scale by `factor`, keeping the world point that was under `from_screen` under `to_screen`.
func _zoom_about(from_screen: Vector2, to_screen: Vector2, factor: float) -> void:
	var w := _screen_to_world(from_screen)
	_zoom = clampf(_zoom * factor, _min_zoom, _max_zoom)
	_focus = w - (to_screen - _free_center) / _zoom
	_apply()


func _screen_to_world(s: Vector2) -> Vector2:
	return _focus + (s - _free_center) / _zoom


# ---------------------------------------------------------------- fit / clamp / apply

func _on_viewport_resized() -> void:
	_recompute(false)


func _recompute(reset: bool) -> void:
	var vp := get_viewport_rect().size
	_free_size = Vector2(vp.x - margin_left - margin_right, vp.y - margin_top - margin_bottom)
	_free_center = Vector2(margin_left, margin_top) + _free_size * 0.5

	var fit := minf(_free_size.x / _world.x, _free_size.y / _world.y)
	_min_zoom = maxf(fit, min_zoom_floor)
	_max_zoom = maxf(max_zoom, _min_zoom)

	if reset:
		_zoom = _min_zoom
		_focus = _world * 0.5
	else:
		_zoom = clampf(_zoom, _min_zoom, _max_zoom)
	_apply()


func _clamp_focus() -> void:
	var half := _free_size / (2.0 * _zoom)   # half of the visible world area, per axis
	for axis in 2:
		if _world[axis] <= half[axis] * 2.0 + 0.5:
			_focus[axis] = _world[axis] * 0.5   # whole axis visible -> keep it centred
		else:
			_focus[axis] = clampf(_focus[axis], half[axis] - pan_margin,
					_world[axis] - half[axis] + pan_margin)


func _apply() -> void:
	_clamp_focus()
	zoom = Vector2(_zoom, _zoom)
	var vp := get_viewport_rect().size
	# Camera position is the world point at the screen centre; shift it so the
	# free area's centre (not the whole screen's) shows _focus.
	position = _focus + (vp * 0.5 - _free_center) / _zoom
	force_update_scroll()
