# save_manager.gd
# Register as an Autoload named "SaveManager" (Project Settings > Globals > Autoload).
# Put it ABOVE GameSession in the list.
extends Node
## Everything the game remembers between sessions, in one JSON file:
##
##   { "version": 1,
##     "maps": {
##       "map_01": { "high_score": 42, "run": { ...snapshot built by game.gd... } }
##     } }
##
## "run" only exists while that map has a saved game. Maps are keyed by
## GameConfig.get_save_id(), so every map has its own run and its own high score.

const SAVE_PATH := "user://metro_save.json"
const FILE_VERSION := 1
## Bump when the snapshot layout changes so old saves are ignored instead of crashing.
const RUN_VERSION := 1

var _maps: Dictionary = {}


func _ready() -> void:
	_load()


# ------------------------------------------------------------------ runs

func has_run(map_id: String) -> bool:
	return not get_run(map_id).is_empty()


## The saved game for this map, or {} if there isn't one (or it is from an incompatible version).
func get_run(map_id: String) -> Dictionary:
	var entry = _maps.get(map_id)
	if not entry is Dictionary:
		return {}
	var run = entry.get("run")
	if not run is Dictionary or int(run.get("v", 0)) != RUN_VERSION:
		return {}
	return run


## Autosave. Also lifts the high score if the run is already past it.
func save_run(map_id: String, snapshot: Dictionary) -> void:
	var entry := _entry(map_id)
	entry["run"] = snapshot
	entry["high_score"] = maxi(get_high_score(map_id), int(snapshot.get("score", 0)))
	_write()


## Called when a run is lost: the high score is kept, the saved game is deleted.
func finish_run(map_id: String, score: int) -> void:
	var entry := _entry(map_id)
	entry["high_score"] = maxi(get_high_score(map_id), score)
	entry.erase("run")
	_write()


## Throws the saved game away (high score stays).
func clear_run(map_id: String) -> void:
	var entry = _maps.get(map_id)
	if entry is Dictionary and entry.has("run"):
		entry.erase("run")
		_write()


# ------------------------------------------------------------ high scores

func get_high_score(map_id: String) -> int:
	var entry = _maps.get(map_id)
	if entry is Dictionary:
		return int(entry.get("high_score", 0))
	return 0


# ------------------------------------------------------------ housekeeping

## Wipes every saved game AND every high score.
func clear_all() -> void:
	_maps.clear()
	_write()


func _entry(map_id: String) -> Dictionary:
	if not _maps.get(map_id) is Dictionary:
		_maps[map_id] = {}
	return _maps[map_id]


func _load() -> void:
	_maps = {}
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
	if parsed is Dictionary and parsed.get("maps") is Dictionary:
		_maps = parsed["maps"]
	else:
		push_warning("SaveManager: %s is unreadable, starting empty." % SAVE_PATH)


func _write() -> void:
	var text := JSON.stringify({"version": FILE_VERSION, "maps": _maps})
	# Write to a temp file first so a crash mid-write can't wipe the real save.
	var tmp := SAVE_PATH + ".tmp"
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		push_error("SaveManager: could not write %s (error %d)" % [tmp, FileAccess.get_open_error()])
		return
	file.store_string(text)
	file.close()
	if DirAccess.rename_absolute(tmp, SAVE_PATH) != OK:
		# Some platforms refuse to rename over an existing file.
		DirAccess.remove_absolute(SAVE_PATH)
		DirAccess.rename_absolute(tmp, SAVE_PATH)
