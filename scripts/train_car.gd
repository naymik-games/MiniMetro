# train_car.gd
class_name TrainCar
extends Node2D
## One vehicle (locomotive or carriage), drawn entirely in code: a rounded body in the
## line colour, a light "window" panel, and the riders' shapes as solid icons.
## The body rotates with the train; the icons keep their own upright orientation.

@export var size: Vector2 = Vector2(40, 33)
@export var corner_radius: int = 4
@export var is_locomotive: bool = false
@export var window_color: Color = Color(1, 1, 1, 0.0)
## Margin kept between the icon grid and the body edge
@export var window_inset: float = 3.0
## Icon diameter as a fraction of the grid cell (1.0 = icons touch)
@export_range(0.3, 1.0) var icon_scale: float = 0.85
## Padding of the light backing pill around the occupied icons
@export var window_padding: float = -1.0
@export var icon_color: Color = Color(0.15, 0.15, 0.18)
## true: icons stay upright while the car turns. false: they rotate with the car.
@export var icons_upright: bool = false

var color: Color = Color.WHITE:
	set(value):
		color = value
		queue_redraw()

var _slots: int = 6
var _columns: int = 3
var _types: PackedStringArray = PackedStringArray()
var _last_rotation: float = INF
var _body := StyleBoxFlat.new()
var _window := StyleBoxFlat.new()


func _ready() -> void:
	_body.anti_aliasing = true
	_window.anti_aliasing = true


## Fixed slot layout, so icons don't shuffle around as people board.
func configure(slots: int, columns: int) -> void:
	_slots = maxi(slots, 1)
	_columns = maxi(columns, 1)
	queue_redraw()


func set_riders(types: PackedStringArray) -> void:
	_types = types
	queue_redraw()


func _process(_delta: float) -> void:
	# Upright icons need a redraw whenever the car's rotation changes.
	if icons_upright and not _types.is_empty() and not is_equal_approx(global_rotation, _last_rotation):
		_last_rotation = global_rotation
		queue_redraw()


func _draw() -> void:
	var rect := Rect2(-size * 0.5, size)
	_body.bg_color = color
	_body.set_corner_radius_all(corner_radius)
	_body.set_border_width_all(2 if is_locomotive else 0)  # darker rim marks the locomotive
	_body.border_color = color.darkened(0.35)
	draw_style_box(_body, rect)
	_draw_riders(rect)


func _draw_riders(rect: Rect2) -> void:
	if _types.is_empty():
		return
	var count := mini(_types.size(), _slots)
	var cols := mini(_columns, _slots)
	var rows := ceili(float(_slots) / float(cols))
	var avail := rect.grow(-window_inset).size
	var cell := minf(avail.x / cols, avail.y / rows)
	var radius := cell * icon_scale * 0.5

	# Only the occupied block is centred and gets a backing pill, so an empty
	# vehicle shows its full line colour.
	var used_cols := mini(count, cols)
	var used_rows := ceili(float(count) / float(cols))
	var block := Vector2(used_cols, used_rows) * cell
	draw_set_transform(Vector2.ZERO, 0.0)
	_window.bg_color = window_color
	_window.set_corner_radius_all(4)
	draw_style_box(_window, Rect2(-block * 0.5, block).grow(window_padding))

	var rot := -global_rotation if icons_upright else 0.0
	for i in count:
		@warning_ignore("integer_division")
		var row := i / cols
		var col := i % cols
		var pos := Vector2((col - (used_cols - 1) * 0.5) * cell, (row - (used_rows - 1) * 0.5) * cell)
		draw_set_transform(pos, rot)  # shapes below are drawn around the origin
		_draw_shape(_types[i], radius)
	draw_set_transform(Vector2.ZERO, 0.0)


## Solid shapes centred on the origin. Edit the names to match your passenger types.
func _draw_shape(type: String, r: float) -> void:
	var col := icon_color
	match type:
		"circle":
			draw_circle(Vector2.ZERO, r, col)
		"square":
			draw_rect(Rect2(Vector2(-r, -r), Vector2(r, r) * 2.0), col)
		"triangle":
			draw_colored_polygon(PackedVector2Array([
				Vector2(0, -r), Vector2(r, r * 0.8), Vector2(-r, r * 0.8)]), col)
		"diamond":
			draw_colored_polygon(PackedVector2Array([
				Vector2(0, -r), Vector2(r, 0), Vector2(0, r), Vector2(-r, 0)]), col)
		"plus":
			var t := r * 0.38
			draw_rect(Rect2(Vector2(-r, -t), Vector2(r * 2.0, t * 2.0)), col)
			draw_rect(Rect2(Vector2(-t, -r), Vector2(t * 2.0, r * 2.0)), col)
		"hexagon":
			draw_colored_polygon(_ngon(6, r, r), col)
		"star":
			draw_colored_polygon(_ngon(10, r, r * 0.45), col)
		_:
			draw_circle(Vector2.ZERO, r, col)  # unknown type: still visible


## Regular polygon; with different outer/inner radii it alternates into a star.
func _ngon(n: int, outer: float, inner: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for k in n:
		var rad := outer if k % 2 == 0 else inner
		pts.append(Vector2.from_angle(TAU * k / n - PI * 0.5) * rad)
	return pts
