# locomotive_ghost.gd
class_name LocomotiveGhost
extends Node2D
## Semi-transparent locomotive rectangle shown while the player drags the Locomotive
## upgrade. Grey and free-floating over empty ground; tinted with the line's colour and
## snapped onto the track (rotated to follow it) when it's over a valid line.

## Match this to your train sprite's on-screen size.
@export var size: Vector2 = Vector2(40,33)

var _snapped: bool = false
var _tint: Color = Color.WHITE


func _init() -> void:
	z_index = 100  # above lines, stations and trains


func show_free(world_pos: Vector2) -> void:
	global_position = world_pos
	rotation = 0.0
	_snapped = false
	queue_redraw()


func show_snapped(world_pos: Vector2, angle: float, line_color: Color) -> void:
	global_position = world_pos
	rotation = angle
	_snapped = true
	_tint = line_color
	queue_redraw()


func _draw() -> void:
	var rect := Rect2(-size * 0.5, size)
	if _snapped:
		draw_rect(rect, Color(_tint, 0.6))
		draw_rect(rect, Color(_tint.darkened(0.3), 0.9), false, 2.0)
	else:
		draw_rect(rect, Color(0.55, 0.55, 0.55, 0.45))
		draw_rect(rect, Color(0.3, 0.3, 0.3, 0.8), false, 2.0)
