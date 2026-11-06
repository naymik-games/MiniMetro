# game_session.gd
# Register as an Autoload named "GameSession"
# (Project Settings > Globals > Autoload).
extends Node

## Adjust these to match your project.
const HOME_SCENE := "res://scenes/home.tscn"
const GAME_SCENE := "res://scenes/game.tscn"

## The config chosen on the home screen. Everything in the game can read this.
var current_config: GameConfig = null
## SaveManager.Mode.CLASSIC or SaveManager.Mode.ENDLESS. Survives "Play again" reloads.
var current_mode: int = SaveManager.Mode.CLASSIC
## Set by start_game(); game.gd reads it once to decide between "resume" and "new game".
var resume_requested: bool = false


func is_endless() -> bool:
	return current_mode == SaveManager.Mode.ENDLESS


func start_game(config: GameConfig, mode: int = SaveManager.Mode.CLASSIC, resume: bool = false) -> void:
	if config == null or not config.is_playable():
		push_error("GameSession: config is missing or has no map scene.")
		return
	current_config = config
	current_mode = mode
	var id := config.get_save_id()
	resume_requested = resume and SaveManager.has_run(id, mode)
	if not resume_requested:
		SaveManager.clear_run(id, mode)  # a new game replaces any saved one in this mode
	get_tree().change_scene_to_file(GAME_SCENE)


func return_home() -> void:
	current_config = null
	get_tree().change_scene_to_file(HOME_SCENE)
