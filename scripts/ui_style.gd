# ui_style.gd
class_name UIStyle
extends RefCounted
## Shared look for menus and pop-ups, taken from the reward screen:
## cream panel, grey cards, dark ink text, small rounded quantity badges.
## All static, nothing to instance or autoload.

const INK := Color("#2b2b2b")
const PAPER := Color("#f4f1ea")
const CARD := Color("#6e6c68")
const CARD_HOVER := Color("#7c7a75")
const CARD_PRESSED := Color("#5f5d59")
const GOLD := Color("#d9a21b")
const BADGE_GREY := Color("#8c8c8c")


static func box(color: Color, radius: int = 10, margin: int = -1) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(radius)
	if margin >= 0:
		sb.set_content_margin_all(margin)
	return sb


static func label(text: String, font_size: int, color: Color = INK, centered: bool = true) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if centered:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l


## kind: &"primary" (dark, light text), &"secondary" (grey card colour, dark text),
## &"light" (cream, dark text; use it on top of grey cards).
static func button(text: String, kind: StringName = &"primary", min_size: Vector2 = Vector2(0, 48)) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = min_size
	b.focus_mode = Control.FOCUS_NONE

	var normal: Color
	var hover: Color
	var pressed: Color
	var fg: Color
	match kind:
		&"secondary":
			normal = CARD
			hover = CARD_HOVER
			pressed = CARD_PRESSED
			fg = INK
		&"light":
			normal = PAPER
			hover = PAPER.darkened(0.05)
			pressed = PAPER.darkened(0.12)
			fg = INK
		_:
			normal = INK
			hover = INK.lightened(0.15)
			pressed = INK.lightened(0.3)
			fg = PAPER

	b.add_theme_stylebox_override("normal", box(normal, 10, 10))
	b.add_theme_stylebox_override("hover", box(hover, 10, 10))
	b.add_theme_stylebox_override("pressed", box(pressed, 10, 10))
	b.add_theme_stylebox_override("disabled", box(normal.darkened(0.1), 10, 10))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	for key in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(key, fg)
	return b


## Small rounded pill, like the quantity badges (gold = special, grey = normal).
static func badge(text: String, color: Color = BADGE_GREY) -> PanelContainer:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := box(color, 13)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	p.add_theme_stylebox_override("panel", sb)
	p.add_child(label(text, 14, Color.WHITE))
	return p


## A grey rounded card. Put content in card_body(card).
static func make_card(min_size: Vector2 = Vector2.ZERO, spacing: int = 8) -> PanelContainer:
	var c := PanelContainer.new()
	c.custom_minimum_size = min_size
	c.add_theme_stylebox_override("panel", box(CARD, 10, 14))
	var body := VBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", spacing)
	c.add_child(body)
	return c


static func card_body(card: PanelContainer) -> VBoxContainer:
	return card.get_node("Body")


## Header row for a card: optional title on the left, badge on the right.
static func card_header(title: String, badge_node: Control = null) -> HBoxContainer:
	var row := HBoxContainer.new()
	var t := label(title, 22, INK, false)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(t)
	if badge_node != null:
		badge_node.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		row.add_child(badge_node)
	return row


## Full-screen modal: dimmed backdrop + centred cream panel. Swallows clicks and keeps
## running while the tree is paused. Add your content to root.get_meta(&"box").
static func create_modal(separation: int = 16) -> Control:
	var root := Control.new()
	root.process_mode = Node.PROCESS_MODE_ALWAYS
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)

	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", box(PAPER, 14, 28))
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", separation)
	panel.add_child(vbox)

	root.set_meta(&"box", vbox)
	return root
