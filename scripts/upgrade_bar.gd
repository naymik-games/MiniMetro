# upgrade_bar.gd
class_name UpgradeBar
extends VBoxContainer
## Left-side toolbar of upgrades. Each button shows an icon (a coloured placeholder
## until you give it a texture) and a solid grey badge in its upper-right corner
## showing how many of that upgrade are available.

signal upgrade_pressed(id: StringName)
signal upgrade_grabbed(id: StringName)  ## mouse went down on the button (start of a drag)

const BUTTON_SIZE := Vector2(64, 64)
const BADGE_DIAMETER := 28.0
const BADGE_COLOR := Color("#8c8c8c")
const SCREEN_MARGIN := 24.0
const BUTTON_SPACING := 18

const UPGRADES := [
	{"id": &"locomotive", "label": "Locomotive", "glyph": "L", "color": Color("#4a7fb5"),
		"icon": preload("res://assets/icons/locomotive.svg")},
	{"id": &"carriage",   "label": "Carriage",   "glyph": "C", "color": Color("#c9803a"),
		"icon": preload("res://assets/icons/carriage.svg")},
	{"id": &"line",       "label": "Line",       "glyph": "N", "color": Color("#5aa469"),
		"icon": preload("res://assets/icons/line.svg")},
	{"id": &"bridge",     "label": "Bridge",     "glyph": "B", "color": Color("#9a6cb8"), "clickable": false,
		"icon": preload("res://assets/icons/bridge.svg")},
	{"id": &"station",    "label": "Station",    "glyph": "S", "color": Color("#c25b6e"),
		"icon": preload("res://assets/icons/station.svg")},
]

## Fallback only: game.gd passes the real starting counts from GameConfig.
const DEFAULT_COUNTS := {
	&"locomotive": 3,
	&"carriage": 2,
	&"line": 1,
	&"bridge": 2,
	&"station": 1,
}
var _buttons: Dictionary = {}       # id -> Button
var _counts: Dictionary = {}        # id -> int
var _badge_labels: Dictionary = {}  # id -> Label
var _placeholders: Dictionary = {}  # id -> Control (the placeholder art)
var _icon_rects: Dictionary = {}    # id -> TextureRect (real icon, once supplied)
var _active_frames: Dictionary = {} # id -> Panel (outline shown while an upgrade is armed)


## Call after adding the bar to the HUD. `counts` maps upgrade id -> quantity.
func setup(counts: Dictionary = DEFAULT_COUNTS) -> void:
	add_theme_constant_override("separation", BUTTON_SPACING)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	for upgrade in UPGRADES:
		var id: StringName = upgrade["id"]
		_counts[id] = int(counts.get(id, 0))
		add_child(_build_button(upgrade))
		if upgrade.has("icon"):
			set_icon(id, upgrade["icon"])
		_refresh_button_visibility(id)
	# Pin to the left edge, vertically centred (the container grows around the centre line).
	anchor_left = 0.0
	anchor_right = 0.0
	anchor_top = 0.5
	anchor_bottom = 0.5
	grow_horizontal = Control.GROW_DIRECTION_END
	grow_vertical = Control.GROW_DIRECTION_BOTH
	offset_left = SCREEN_MARGIN
	offset_right = SCREEN_MARGIN + BUTTON_SIZE.x
	offset_top = 0.0
	offset_bottom = 0.0


# ---------------------------------------------------------------- public API

func get_count(id: StringName) -> int:
	return _counts.get(id, 0)


func set_count(id: StringName, value: int) -> void:
	if not _counts.has(id):
		return
	_counts[id] = maxi(value, 0)
	(_badge_labels[id] as Label).text = str(_counts[id])
	_refresh_button_visibility(id)


func add_count(id: StringName, delta: int = 1) -> void:
	set_count(id, get_count(id) + delta)


## Shows / hides a white outline on the button (used while an upgrade is armed).
func set_active(id: StringName, active: bool) -> void:
	if _active_frames.has(id):
		(_active_frames[id] as Panel).visible = active


## Swap the placeholder for a real icon. Pass null to go back to the placeholder.
func set_icon(id: StringName, texture: Texture2D) -> void:
	if not _icon_rects.has(id):
		return
	(_icon_rects[id] as TextureRect).texture = texture
	(_placeholders[id] as Control).visible = texture == null

## A button is only shown while at least one of that upgrade is available.
## Hidden children take no space in the VBoxContainer, so the bar re-centres itself.
func _refresh_button_visibility(id: StringName) -> void:
	if _buttons.has(id):
		(_buttons[id] as Button).visible = _counts[id] > 0
# ---------------------------------------------------------------- building

func _build_button(upgrade: Dictionary) -> Button:
	var id: StringName = upgrade["id"]

	var button := Button.new()
	button.custom_minimum_size = BUTTON_SIZE
	button.tooltip_text = upgrade["label"]
	button.focus_mode = Control.FOCUS_NONE
	
	# Strip the grey background in every state so only the icon shows.
	var empty := StyleBoxEmpty.new()
	for style_name in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		button.add_theme_stylebox_override(style_name, empty)
	
	if upgrade.get("clickable", true):
		button.pressed.connect(func(): upgrade_pressed.emit(id))
		button.button_down.connect(func(): upgrade_grabbed.emit(id))
	else:
		# Passive counter: ignores clicks (and still swallows them, so they don't
		# fall through to the map) but is drawn like the other buttons.
		button.disabled = true
		#button.add_theme_stylebox_override("disabled", button.get_theme_stylebox("normal", "Button"))
		button.tooltip_text = "%s (used automatically)" % upgrade["label"]
	# Real icon (hidden until a texture is set)
	var icon_rect := TextureRect.new()
	icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 8)
	button.add_child(icon_rect)
	_icon_rects[id] = icon_rect

	# Placeholder: rounded coloured tile with the upgrade's initial
	var placeholder := Panel.new()
	placeholder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	placeholder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 2)
	var tile := StyleBoxFlat.new()
	tile.bg_color = upgrade["color"]
	tile.set_corner_radius_all(8)
	placeholder.add_theme_stylebox_override("panel", tile)
	placeholder.add_child(_make_centered_label(upgrade["glyph"], 22, Color.WHITE))
	button.add_child(placeholder)
	_placeholders[id] = placeholder

	# Selection outline (hidden until set_active)
	var frame := Panel.new()
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var outline := StyleBoxFlat.new()
	outline.bg_color = Color(1, 1, 1, 0.15)
	outline.border_color = Color.WHITE
	outline.set_border_width_all(3)
	outline.set_corner_radius_all(10)
	frame.add_theme_stylebox_override("panel", outline)
	frame.visible = false
	button.add_child(frame)
	_active_frames[id] = frame

	button.add_child(_build_badge(id))
	_buttons[id] = button
	return button



## Solid grey circle with the quantity, overlapping the button's upper-right corner.
func _build_badge(id: StringName) -> Panel:
	var badge := Panel.new()
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.custom_minimum_size = Vector2(BADGE_DIAMETER, BADGE_DIAMETER)
	badge.size = Vector2(BADGE_DIAMETER, BADGE_DIAMETER)
	badge.position = Vector2(BUTTON_SIZE.x - BADGE_DIAMETER * 0.65, -BADGE_DIAMETER * 0.35)

	var circle := StyleBoxFlat.new()
	circle.bg_color = BADGE_COLOR
	circle.set_corner_radius_all(int(BADGE_DIAMETER / 2.0))
	badge.add_theme_stylebox_override("panel", circle)

	var label := _make_centered_label(str(_counts[id]), 13, Color.WHITE)
	badge.add_child(label)
	_badge_labels[id] = label
	return badge


func _make_centered_label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return label

static func get_upgrade_def(id: StringName) -> Dictionary:
	for upgrade in UPGRADES:
		if upgrade["id"] == id:
			return upgrade
	return {}


func get_icon(id: StringName) -> Texture2D:
	if not _icon_rects.has(id):
		return null
	return (_icon_rects[id] as TextureRect).texture
