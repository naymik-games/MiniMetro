# clock_hud.gd
class_name ClockHud
extends HBoxContainer
## Top-right HUD widget: a week dial (7 day segments that fill as the week
## goes by) plus pause / normal / fast / 20x speed buttons.
## Created from game.gd and added to the HUD CanvasLayer, like LineBar.
##
## Keys: Space = pause/resume, 1 = normal, 2 = fast, 3 = 20x.
signal hud_visibility_toggled(hud_visible: bool)

const ICON_VISIBLE := preload("res://assets/icons/visible_on.svg")
const ICON_HIDDEN := preload("res://assets/icons/visibility_off.svg")
const INK := Color("#2b2b2b")
const TRACK := Color(0.17, 0.17, 0.17, 0.16)
const BUTTON_BG := Color(1, 1, 1, 0.6)
const BUTTON_BG_HOVER := Color(1, 1, 1, 0.9)

const DIAL_SIZE := 64.0
const DIAL_THICKNESS := 6.0
const SCREEN_MARGIN := 16.0
var _speed_row: HBoxContainer
var _toggle_button: Button
var _hud_visible := true
var _buttons: Dictionary = {}  # speed -> SpeedButton


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE  # only the buttons catch clicks
	alignment = BoxContainer.ALIGNMENT_END
	add_theme_constant_override("separation", 14)

	add_child(WeekDial.new())

	var row := HBoxContainer.new()
	_speed_row = row
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_theme_constant_override("separation", 6)
	add_child(row)

	var group := ButtonGroup.new()
	for speed in [GameClock.Speed.PAUSED, GameClock.Speed.NORMAL, GameClock.Speed.FAST, GameClock.Speed.ULTRA]:
		var button := SpeedButton.new()
		button.setup(speed, group)
		button.pressed.connect(func(): GameClock.set_speed(speed))
		row.add_child(button)
		_buttons[speed] = button

	_toggle_button = _build_toggle_button()
	add_child(_toggle_button)

	GameClock.speed_changed.connect(_on_speed_changed)
	_on_speed_changed(GameClock.speed)

	# Pin to the top-right corner; grow leftwards so nothing jumps around.
	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, int(SCREEN_MARGIN))
	grow_horizontal = Control.GROW_DIRECTION_BEGIN




func _on_speed_changed(speed: int) -> void:
	if _buttons.has(speed):
		# Setting button_pressed unpresses the others in the group, and does
		# not emit `pressed`, so this can't loop back into set_speed().
		(_buttons[speed] as SpeedButton).button_pressed = true

func _build_toggle_button() -> Button:
	var button := Button.new()
	button.icon = ICON_VISIBLE
	button.expand_icon = true
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(44, 64)
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	button.tooltip_text = "Hide controls"
	button.add_theme_constant_override("icon_max_width", 24)
	#for color_name in ["icon_normal_color", "icon_hover_color", "icon_pressed_color",
			#"icon_hover_pressed_color", "icon_focus_color"]:
		#button.add_theme_color_override(color_name, INK)

	var normal := StyleBoxFlat.new()
	normal.bg_color = BUTTON_BG
	normal.set_corner_radius_all(8)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = BUTTON_BG_HOVER
	for style_name in ["normal", "pressed", "focus"]:
		button.add_theme_stylebox_override(style_name, normal)
	for style_name in ["hover", "hover_pressed"]:
		button.add_theme_stylebox_override(style_name, hover)

	button.pressed.connect(_on_toggle_pressed)
	return button


func _on_toggle_pressed() -> void:
	_hud_visible = not _hud_visible
	_speed_row.visible = _hud_visible
	_toggle_button.icon = ICON_VISIBLE if _hud_visible else ICON_HIDDEN
	_toggle_button.tooltip_text = "Hide controls" if _hud_visible else "Show controls"
	hud_visibility_toggled.emit(_hud_visible)

func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	match key.keycode:
		KEY_SPACE:
			GameClock.toggle_pause()
		KEY_1:
			GameClock.set_speed(GameClock.Speed.NORMAL)
		KEY_2:
			GameClock.set_speed(GameClock.Speed.FAST)
		KEY_3:
			GameClock.set_speed(GameClock.Speed.ULTRA)
		_:
			return
	get_viewport().set_input_as_handled()


# ------------------------------------------------------------------ dial

class WeekDial extends Control:
	const GAP := 0.16  # radians left between day segments

	func _init() -> void:
		custom_minimum_size = Vector2(DIAL_SIZE, DIAL_SIZE)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _ready() -> void:
		GameClock.ticked.connect(func(_dt): queue_redraw())
		GameClock.speed_changed.connect(func(_s): queue_redraw())

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5 - DIAL_THICKNESS * 0.5 - 1.0
		var seg := TAU / GameClock.DAYS_PER_WEEK
		var progress := GameClock.week_progress * GameClock.DAYS_PER_WEEK  # 0..7

		for i in GameClock.DAYS_PER_WEEK:
			var a0 := -PI / 2.0 + seg * i + GAP * 0.5
			var a1 := -PI / 2.0 + seg * (i + 1) - GAP * 0.5
			draw_arc(c, r, a0, a1, 16, TRACK, DIAL_THICKNESS, true)
			var f := clampf(progress - i, 0.0, 1.0)
			if f > 0.0:
				draw_arc(c, r, a0, lerpf(a0, a1, f), 16, INK, DIAL_THICKNESS, true)

		var font := get_theme_default_font()
		draw_string(font, Vector2(0, c.y + 2), str(GameClock.week + 1),
				HORIZONTAL_ALIGNMENT_CENTER, size.x, 20, INK)
		draw_string(font, Vector2(0, c.y + 16), GameClock.DAY_NAMES[GameClock.day_of_week],
				HORIZONTAL_ALIGNMENT_CENTER, size.x, 11, Color(INK, 0.6))


# --------------------------------------------------------------- buttons

class SpeedButton extends Button:
	var speed: int = GameClock.Speed.NORMAL

	func setup(p_speed: int, group: ButtonGroup) -> void:
		speed = p_speed
		toggle_mode = true
		button_group = group
		focus_mode = Control.FOCUS_NONE  # so Space never "clicks" a button
		custom_minimum_size = Vector2(44, 64)
		tooltip_text = ["Pause (Space)", "Normal (1)", "Fast (2)", "10x (3)"][p_speed]

		add_theme_stylebox_override("normal", _box(BUTTON_BG))
		add_theme_stylebox_override("hover", _box(BUTTON_BG_HOVER))
		add_theme_stylebox_override("pressed", _box(INK))
		add_theme_stylebox_override("hover_pressed", _box(INK))
		add_theme_stylebox_override("focus", StyleBoxEmpty.new())

	func _box(color: Color) -> StyleBoxFlat:
		var box := StyleBoxFlat.new()
		box.bg_color = color
		box.set_corner_radius_all(8)
		return box

	func _draw() -> void:
		var col := Color.WHITE if button_pressed else INK
		var c := size * 0.5
		var h := 7.0  # half icon height

		match speed:
			GameClock.Speed.PAUSED:
				draw_rect(Rect2(c.x - 6.0, c.y - h, 4.0, h * 2.0), col)
				draw_rect(Rect2(c.x + 2.0, c.y - h, 4.0, h * 2.0), col)
			GameClock.Speed.NORMAL:
				_draw_triangles(c, h, 1, col)
			GameClock.Speed.FAST:
				_draw_triangles(c, h, 2, col)
			GameClock.Speed.ULTRA:
				var font := get_theme_default_font()
				var text := "10x"
				var fs := 15
				var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
				var y := c.y + (font.get_ascent(fs) - font.get_descent(fs)) * 0.5
				draw_string(font, Vector2(c.x - w * 0.5, y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)

	func _draw_triangles(c: Vector2, h: float, count: int, col: Color) -> void:
		var w := h * 1.1
		var gap := 1.5
		var x := c.x - (w * count + gap * (count - 1)) * 0.5
		for i in count:
			draw_colored_polygon(PackedVector2Array([
				Vector2(x, c.y - h), Vector2(x + w, c.y), Vector2(x, c.y + h),
			]), col)
			x += w + gap
