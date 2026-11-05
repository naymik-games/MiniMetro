# reward_screen.gd
class_name RewardScreen
extends Control
## End-of-week reward picker. Shows 2 or 3 upgrade cards (same icons as the
## UpgradeBar, with a quantity badge) and emits reward_chosen when one is clicked.
##
## Pausing is done by game.gd (get_tree().paused = true); this node runs in
## PROCESS_MODE_ALWAYS so its buttons still work while the game is paused.

signal reward_chosen(id: StringName, amount: int)

## Chance that an offered reward is x2 instead of x1.
const DOUBLE_CHANCE := 0.2
## Chance the screen offers 3 rewards instead of 2.
const THREE_CHOICES_CHANCE := 0.5

## How often each upgrade shows up. Higher = more common.
const WEIGHTS := {
	&"locomotive": 3.0,
	&"carriage": 3.0,
	&"line": 1.5,
	&"bridge": 2.0,
	&"station": 2.0,
}

const CARD_SIZE := Vector2(124, 150)
const INK := Color("#2b2b2b")
const BADGE_X1 := Color("#8c8c8c")
const BADGE_X2 := Color("#d9a21b")


## Builds the UI. `bar` is only used to borrow its icons so the cards always
## match the upgrade bar (placeholder tiles or real textures).
func setup(bar: UpgradeBar, weeks_completed: int) -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_STOP  # swallow clicks so nothing behind is touched
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	var panel_box := StyleBoxFlat.new()
	panel_box.bg_color = Color("#f4f1ea")
	panel_box.set_corner_radius_all(14)
	panel_box.set_content_margin_all(28)
	panel.add_theme_stylebox_override("panel", panel_box)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	panel.add_child(box)

	var title := Label.new()
	title.text = "Week %d complete" % weeks_completed
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", INK)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Choose a reward"
	subtitle.add_theme_color_override("font_color", Color(INK, 0.65))
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(subtitle)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(row)

	for offer in roll_offers():
		row.add_child(_build_card(offer, bar))


# ---------------------------------------------------------------- rolling

## Returns 2 or 3 offers like [{"id": &"bridge", "amount": 2}, ...] with no
## upgrade type repeated.
static func roll_offers() -> Array[Dictionary]:
	var count := 3 if randf() < THREE_CHOICES_CHANCE else 2
	var pool: Dictionary = WEIGHTS.duplicate()
	var offers: Array[Dictionary] = []
	for i in count:
		var id := _pick_weighted(pool)
		pool.erase(id)
		var amount := 2 if randf() < DOUBLE_CHANCE else 1
		offers.append({"id": id, "amount": amount})
	return offers


static func _pick_weighted(pool: Dictionary) -> StringName:
	var total := 0.0
	for id in pool:
		total += float(pool[id])
	var roll := randf() * total
	for id in pool:
		roll -= float(pool[id])
		if roll <= 0.0:
			return id
	return pool.keys()[0]


# ---------------------------------------------------------------- cards

func _build_card(offer: Dictionary, bar: UpgradeBar) -> Button:
	var id: StringName = offer["id"]
	var amount: int = offer["amount"]
	var def := UpgradeBar.get_upgrade_def(id)

	var card := Button.new()
	card.custom_minimum_size = CARD_SIZE
	card.focus_mode = Control.FOCUS_NONE
	card.tooltip_text = "%s x%d" % [def.get("label", String(id)), amount]
	card.pressed.connect(func(): _choose(id, amount))

	# Icon: real texture if the bar has one, otherwise the same placeholder tile.
	var icon_pos := Vector2((CARD_SIZE.x - 64.0) * 0.5, 22.0)
	var texture := bar.get_icon(id)
	if texture != null:
		var rect := TextureRect.new()
		rect.texture = texture
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rect.position = icon_pos
		rect.size = Vector2(64, 64)
		card.add_child(rect)
	else:
		var tile_panel := Panel.new()
		tile_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tile_panel.position = icon_pos
		tile_panel.size = Vector2(64, 64)
		var tile := StyleBoxFlat.new()
		tile.bg_color = def.get("color", Color.GRAY)
		tile.set_corner_radius_all(10)
		tile_panel.add_theme_stylebox_override("panel", tile)
		tile_panel.add_child(_label(str(def.get("glyph", "?")), 30, Color.WHITE, true))
		card.add_child(tile_panel)

	var name_label := _label(str(def.get("label", String(id))), 15, INK, false)
	name_label.position = Vector2(0, 100)
	name_label.size = Vector2(CARD_SIZE.x, 24)
	card.add_child(name_label)

	var amount_label := _label("+%d" % amount, 18, BADGE_X2.darkened(0.25) if amount > 1 else Color(INK, 0.7), false)
	amount_label.position = Vector2(0, 120)
	amount_label.size = Vector2(CARD_SIZE.x, 24)
	card.add_child(amount_label)

	# Quantity badge, upper-right, like the bar's (gold for the rarer x2).
	var badge := Panel.new()
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.size = Vector2(34, 26)
	badge.position = Vector2(CARD_SIZE.x - 34.0 * 0.7, -26.0 * 0.35)
	var badge_box := StyleBoxFlat.new()
	badge_box.bg_color = BADGE_X2 if amount > 1 else BADGE_X1
	badge_box.set_corner_radius_all(13)
	badge.add_theme_stylebox_override("panel", badge_box)
	badge.add_child(_label("x%d" % amount, 14, Color.WHITE, true))
	card.add_child(badge)

	return card


func _choose(id: StringName, amount: int) -> void:
	reward_chosen.emit(id, amount)
	queue_free()


func _label(text: String, font_size: int, color: Color, fill: bool) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	if fill:
		label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return label
