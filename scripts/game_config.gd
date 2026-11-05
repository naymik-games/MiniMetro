# game_config.gd
class_name GameConfig
extends Resource
## Describes one playable map/level. Save each one as a .tres file
## (e.g. res://configs/map_01.tres) and add it to the home screen's list.

@export_group("Level")
## Shown on the home screen.
@export var display_name: String = "Untitled Map"
## Scene instanced at game start. Its root must use map.gd (is_land / water_crossings).
@export var map_scene: PackedScene
## Optional. Key for this map's saved game and high score. Leave empty to use the .tres file name
## (e.g. "map_01"). Set it explicitly if you ever rename the file, or the old save is orphaned.
@export var save_id: String = ""

@export_group("Stations")
## Stations spawned immediately when the game opens.
@export_range(1, 30) var starting_stations: int = 3

@export_group("Passenger Demand")
## How fast passenger spawning ramps up over time. 0 = flat forever, 1 = normal, 2 = twice as steep.
@export_range(0.0, 5.0, 0.1) var passenger_spawn_aggression: float = 1.0
## Turn special events (demand spikes at plus / hexagon / star stations) on or off for this map.
@export var demand_events_enabled: bool = true
## Seconds into the game before the first event can start.
@export var first_event_delay: float = 60.0
## Random pause between the end of one event and the start of the next.
@export var event_gap_min: float = 45.0
@export var event_gap_max: float = 90.0
## How long an event lasts, in seconds.
@export var event_duration: float = 30.0
## During an event, how much more likely passengers are to pick the venue shape as their destination.
@export var event_demand_boost: float = 4.0
## During an event, extra passenger rate at every station except the venue (1.0 = no change).
@export var event_rate_boost: float = 1.5

# ------------------------------------------------------------------
# FUTURE: stored here already, but nothing reads them yet.
# ------------------------------------------------------------------

@export_group("Lines (future)")
## Lines the player can use at the start.
@export_range(1, 10) var starting_lines: int = 3
## Upper limit on lines, even after unlocks. 10 max
@export_range(1, 10) var max_lines: int = 7

@export_group("Economy / Starting Upgrades")
## Not used yet, kept for future gameplay.
@export var starting_budget: int = 0
## Upgrade counts the player starts a new game with (shown on the upgrade bar).
@export_range(0, 99) var trains_in_reserve: int = 3          ## locomotives
@export_range(0, 99) var carriages_in_reserve: int = 2
@export_range(0, 99) var line_upgrades_in_reserve: int = 1   ## extra line slots (still capped by max_lines)
@export_range(0, 99) var station_upgrades_in_reserve: int = 1
@export_range(0, 99) var starting_bridges: int = 2
@export_group("Difficulty (future)")
## Multiplier on how quickly new stations appear. 1.0 = normal, 2.0 = twice as fast.
@export_range(0.1, 5.0, 0.1) var station_spawn_aggression: float = 1.0


## A config is only playable if it points at a map.
func is_playable() -> bool:
	return map_scene != null


## Stable key used by SaveManager.
func get_save_id() -> String:
	if save_id != "":
		return save_id
	if resource_path != "" and not "::" in resource_path:
		return resource_path.get_file().get_basename()
	return display_name


## Starting counts for the upgrade bar, keyed by upgrade id.
func get_starting_upgrade_counts() -> Dictionary:
	return {
		&"locomotive": trains_in_reserve,
		&"carriage": carriages_in_reserve,
		&"line": line_upgrades_in_reserve,
		&"bridge": starting_bridges,
		&"station": station_upgrades_in_reserve,
	}
