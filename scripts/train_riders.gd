# train_riders.gd
## Draws the passengers riding a train as a small grid of shape icons.
## Added to the train as a child, it stays upright however the train is facing.
class_name TrainRiders
extends Node2D

@export var icon_size: float = 7.0
## Distance between icon origins (icon_size + gap)
@export var spacing: float = 8.0
## Icons per row; with a capacity of 12 this gives two rows of six
@export var columns: int = 6
## Nudge the whole grid to sit on the carriage
@export var offset: Vector2 = Vector2.ZERO
## Light pill behind the icons so they read on any line colour. Alpha 0 turns it off.
@export var backing_color: Color = Color(1, 1, 1, 0.9)
@export var backing_padding: float = 2.0

var _types: PackedStringArray = PackedStringArray()
var _icon_source: Area2D  ## any station: it owns the shape textures
var _backing := StyleBoxFlat.new()


func _ready() -> void:
	_backing.set_corner_radius_all(3)


func _process(_delta: float) -> void:
	# The train is a PathFollow2D and rotates along the track; counter that.
	global_rotation = 0.0


## Snapshots the riders' shapes and redraws. Call whenever the train's riders change.
func show_riders(riders: Array[Passenger], icon_source: Area2D) -> void:
	_icon_source = icon_source
	_types.clear()
	for p in riders:
		_types.append(p.target_type)
	queue_redraw()


func _draw() -> void:
	if _types.is_empty() or _icon_source == null:
		return

	var count := _types.size()
	var cols := mini(count, columns)
	var rows := ceili(float(count) / float(columns))
	var gap := spacing - icon_size
	var grid_size := Vector2(cols * spacing - gap, rows * spacing - gap)
	var top_left := offset - grid_size / 2.0

	if backing_color.a > 0.0:
		_backing.bg_color = backing_color
		var pad := Vector2.ONE * backing_padding
		draw_style_box(_backing, Rect2(top_left - pad, grid_size + pad * 2.0))

	for i in count:
		@warning_ignore("integer_division")
		var row := i / columns
		var col := i % columns
		# Centre each row on its own, so a short last row sits in the middle
		var in_row := mini(columns, count - row * columns)
		var row_width := in_row * spacing - gap
		var x := offset.x - row_width / 2.0 + col * spacing
		var y := top_left.y + row * spacing

		var tex: Texture = _icon_source._get_texture_for_type(_types[i])
		if tex:
			draw_texture_rect(tex, Rect2(Vector2(x, y), Vector2(icon_size, icon_size)), false)
