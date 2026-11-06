# save_manager.gd
# Register as an Autoload named "SaveManager" (Project Settings > Globals > Autoload).
# Put it ABOVE GameSession in the list.
extends Node
## Everything the game remembers between sessions, in one JSON file:
##
##   { "version": 1,
##     "settings": { "last_mode": 0 },
##     "maps": {
##       "map_01": { "high_score": 42,
##                   "run": { ...Classic snapshot... },
##                   "endless_run": { ...Endless snapshot... } }
##     } }
##
## Every map has one saved game per mode. Only Classic has a high score.
## Old save files (no "settings", no "endless_run") load fine.

const SAVE_PATH := "user://metro_save.json"
const FILE_VERSION := 1
## Bump when the snapshot layout changes so old saves are ignored instead of crashing.
const RUN_VERSION := 1

enum Mode { CLASSIC, ENDLESS }

var _maps: Dictionary = {}
var _settings: Dictionary = {}


func _ready() -> void:
	_load()


# --------------------------------------------------------------- settings

## The mode that was selected on the home screen last time.
func get_last_mode() -> int:
	var m := int(_settings.get("last_mode", Mode.CLASSIC))
	return m if m == Mode.ENDLESS else Mode.CLASSIC


func set_last_mode(mode: int) -> void:
	if get_last_mode() == mode and _settings.has("last_mode"):
		return
	_settings["last_mode"] = mode
	_write()


# ------------------------------------------------------------------ runs

static func _run_key(mode: int) -> String:
	return "endless_run" if mode == Mode.ENDLESS else "run"


func has_run(map_id: String, mode: int = Mode.CLASSIC) -> bool:
	return not get_run(map_id, mode).is_empty()


## True if any map has a saved game in this mode (the home screen's toggle dot).
func has_any_run(mode: int) -> bool:
	for map_id in _maps.keys():
		if has_run(str(map_id), mode):
			return true
	return false


## The saved game for this map and mode, or {} if there isn't one (or it is from an incompatible version).
func get_run(map_id: String, mode: int = Mode.CLASSIC) -> Dictionary:
	var entry = _maps.get(map_id)
	if not entry is Dictionary:
		return {}
	var run = entry.get(_run_key(mode))
	if not run is Dictionary or int(run.get("v", 0)) != RUN_VERSION:
		return {}
	return run


## Autosave. In Classic this also lifts the high score if the run is already past it.
## Endless never touches high scores.
func save_run(map_id: String, snapshot: Dictionary, mode: int = Mode.CLASSIC) -> void:
	var entry := _entry(map_id)
	entry[_run_key(mode)] = snapshot
	if mode == Mode.CLASSIC:
		entry["high_score"] = maxi(get_high_score(map_id), int(snapshot.get("score", 0)))
	_write()


## Called when a Classic run is lost: the high score is kept, the saved game is deleted.
## (Endless runs never end this way.)
func finish_run(map_id: String, score: int) -> void:
	var entry := _entry(map_id)
	entry["high_score"] = maxi(get_high_score(map_id), score)
	entry.erase(_run_key(Mode.CLASSIC))
	_write()


## Throws the saved game for this mode away (high score stays).
func clear_run(map_id: String, mode: int = Mode.CLASSIC) -> void:
	var entry = _maps.get(map_id)
	var key := _run_key(mode)
	if entry is Dictionary and entry.has(key):
		entry.erase(key)
		_write()


# ------------------------------------------------------------ high scores

## Classic only.
func get_high_score(map_id: String) -> int:
	var entry = _maps.get(map_id)
	if entry is Dictionary:
		return int(entry.get("high_score", 0))
	return 0


# ------------------------------------------------------------ housekeeping

## Wipes every saved game (both modes) AND every high score.
## The remembered mode selection is kept.
func clear_all() -> void:
	_maps.clear()
	_write()


func _entry(map_id: String) -> Dictionary:
	if not _maps.get(map_id) is Dictionary:
		_maps[map_id] = {}
	return _maps[map_id]


func _load() -> void:
	_maps = {}
	_settings = {}
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
	if parsed is Dictionary and parsed.get("maps") is Dictionary:
		_maps = parsed["maps"]
		if parsed.get("settings") is Dictionary:
			_settings = parsed["settings"]
	else:
		push_warning("SaveManager: %s is unreadable, starting empty." % SAVE_PATH)


func _write() -> void:
	var text := JSON.stringify({"version": FILE_VERSION, "settings": _settings, "maps": _maps})
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
