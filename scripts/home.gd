# home.gd
# Attach to the root Control of res://scenes/home.tscn
extends Control

## Drag your GameConfig .tres files in here (Inspector). One card per config.
@export var configs: Array[GameConfig] = []

const CARD_WIDTH := 230.0
const CARD_GAP := 18.0
const MAX_ROW_WIDTH := 900.0

var _ui: Control
var _pending_new: GameConfig
var _confirm_new: ConfirmationDialog
var _confirm_clear: ConfirmationDialog


func _ready() -> void:
	_confirm_new = ConfirmationDialog.new()
	_confirm_new.dialog_text = "Start a new game on this map?\nYour saved progress will be lost."
	_confirm_new.ok_button_text = "Start new"
	_confirm_new.confirmed.connect(func(): GameSession.start_game(_pending_new, false))
	add_child(_confirm_new)

	_confirm_clear = ConfirmationDialog.new()
	_confirm_clear.dialog_text = "Delete ALL saved games and high scores?\nThis can't be undone."
	_confirm_clear.ok_button_text = "Delete everything"
	_confirm_clear.confirmed.connect(func():
		SaveManager.clear_all()
		_build_ui())
	add_child(_confirm_clear)

	_build_ui()


func _build_ui() -> void:
	if _ui != null:
		_ui.queue_free()

	var center := CenterContainer.new()
	add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ui = center

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UIStyle.box(UIStyle.PAPER, 14, 28))
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	panel.add_child(box)

	box.add_child(UIStyle.label("Select a Map", 30))
	box.add_child(UIStyle.label("Choose where to play", 16, Color(UIStyle.INK, 0.65)))

	var cards: Array[Control] = []
	for config in configs:
		if config == null or not config.is_playable():
			continue
		cards.append(_build_map_card(config))

	if cards.is_empty():
		box.add_child(UIStyle.label("No playable maps configured.", 16, Color(UIStyle.INK, 0.65)))
	else:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", int(CARD_GAP))
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		for card in cards:
			row.add_child(card)

		# Scrolls sideways if there are more maps than fit on screen.
		var scroll := ScrollContainer.new()
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
		scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		var row_width := cards.size() * CARD_WIDTH + (cards.size() - 1) * CARD_GAP
		scroll.custom_minimum_size.x = minf(row_width + 4.0, MAX_ROW_WIDTH)
		scroll.add_child(row)
		box.add_child(scroll)

	var clear := UIStyle.button("Clear all saved data", &"secondary", Vector2(0, 40))
	clear.pressed.connect(func(): _confirm_clear.popup_centered())
	box.add_child(clear)


func _build_map_card(config: GameConfig) -> Control:
	var id := config.get_save_id()
	var run := SaveManager.get_run(id)
	var best := SaveManager.get_high_score(id)

	var card := UIStyle.make_card(Vector2(CARD_WIDTH, 0), 10)
	var col := UIStyle.card_body(card)

	# Name on the left, best score as a badge on the right.
	var best_badge := UIStyle.badge("Best %d" % best, UIStyle.GOLD if best > 0 else UIStyle.BADGE_GREY)
	col.add_child(UIStyle.card_header(config.display_name, best_badge))

	var info_text := "No saved game"
	if not run.is_empty():
		var week := floori(int(run.get("day", 0)) / float(GameClock.DAYS_PER_WEEK)) + 1
		info_text = "Week %d\n%d delivered" % [week, int(run.get("score", 0))]
	var info := UIStyle.label(info_text, 15, Color(UIStyle.INK, 0.8), false)
	info.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(info)

	if not run.is_empty():
		var resume := UIStyle.button("Resume", &"primary")
		resume.pressed.connect(GameSession.start_game.bind(config, true))
		col.add_child(resume)

	var play_new := UIStyle.button("Play New", &"light")
	play_new.pressed.connect(_on_play_new.bind(config, not run.is_empty()))
	col.add_child(play_new)

	return card


func _on_play_new(config: GameConfig, has_save: bool) -> void:
	if has_save:
		_pending_new = config
		_confirm_new.popup_centered()  # don't silently throw a saved game away
	else:
		GameSession.start_game(config, false)
