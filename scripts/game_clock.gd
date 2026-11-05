# game_clock.gd
# Register as an Autoload named "GameClock"
# (Project Settings > Globals > Autoload).
extends Node
## The game's single source of time.
##
## Everything that used to run on the real frame time (trains, passenger and
## station spawning, overcrowding, demand events...) now asks this clock for
## "game time" instead:
##
##     func _process(real_delta: float) -> void:
##         var delta := GameClock.scaled(real_delta)   # 0 when paused, 20x on ULTRA
##
## The clock also counts days and weeks from that same scaled time, so the
## calendar can never drift away from what the trains are doing.
##
## It stops by itself while get_tree().paused is true (your game-over screen).

## Every frame the clock is running, with the game seconds that just passed.
signal ticked(dt: float)
signal speed_changed(speed: int)
## Absolute day count, starting at 1 (day 0 is the moment the game starts).
signal day_started(day: int)
## Absolute week count, starting at 1.
signal week_started(week: int)

enum Speed { PAUSED, NORMAL, FAST, ULTRA }

const SPEED_MULTIPLIERS := {
	Speed.PAUSED: 0.0,
	Speed.NORMAL: 1.0,   # the speed the game ran at before the clock existed
	Speed.FAST: 3.0,
	Speed.ULTRA: 10.0,
}

const DAYS_PER_WEEK := 7
const DAY_NAMES: Array[String] = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

## Real seconds one day lasts at NORMAL speed (a week = 7x this).
var seconds_per_day: float = 10.0

var speed: int = Speed.NORMAL
var time_scale: float = 1.0
## Game seconds since the run started (stops while paused, runs 20x on ULTRA).
var game_time: float = 0.0
## Whole days completed so far.
var day: int = 0

var _resume_speed: int = Speed.NORMAL


# ------------------------------------------------------------- calendar

## Whole weeks completed so far (0 during the first week). Show week + 1.
var week: int:
	get:
		return floori(day / float(DAYS_PER_WEEK))

## 0 = Mon ... 6 = Sun
var day_of_week: int:
	get:
		return day % DAYS_PER_WEEK

var week_length: float:
	get:
		return seconds_per_day * DAYS_PER_WEEK

## 0..1 through the current week, smooth (not stepped per day).
var week_progress: float:
	get:
		return fposmod(game_time, week_length) / week_length

## 0..1 through the current day.
var day_progress: float:
	get:
		return fposmod(game_time, seconds_per_day) / seconds_per_day


# ---------------------------------------------------------------- clock

func _process(real_delta: float) -> void:
	var dt := real_delta * time_scale
	if dt <= 0.0:
		return

	game_time += dt

	# A big frame at 20x could cross more than one day, so loop.
	var target_day := floori(game_time / seconds_per_day)
	while day < target_day:
		day += 1
		day_started.emit(day)
		if day % DAYS_PER_WEEK == 0:
			week_started.emit(day / DAYS_PER_WEEK)

	ticked.emit(dt)


## Convert a frame's real delta into game time. Use this in every _process.
func scaled(real_delta: float) -> float:
	return real_delta * time_scale


func set_speed(new_speed: int) -> void:
	if new_speed == speed:
		return
	speed = new_speed
	time_scale = SPEED_MULTIPLIERS[new_speed]
	if new_speed != Speed.PAUSED:
		_resume_speed = new_speed
	speed_changed.emit(new_speed)


## Pause, or go back to whatever speed was running before the pause.
func toggle_pause() -> void:
	set_speed(_resume_speed if speed == Speed.PAUSED else Speed.PAUSED)


func is_paused() -> bool:
	return speed == Speed.PAUSED


## Puts the calendar back where a saved game left it. Call right after reset().
## Day progress is a 0..1 fraction so a changed seconds_per_day can't break the calendar.
## Emits nothing, so no day/week signals fire for the days already played.
func restore(saved_day: int, saved_day_progress: float = 0.0) -> void:
	day = maxi(saved_day, 0)
	game_time = (day + clampf(saved_day_progress, 0.0, 0.999)) * seconds_per_day


## Call when a run starts. Pass a value to change how long a day lasts.
func reset(new_seconds_per_day: float = 0.0) -> void:
	if new_seconds_per_day > 0.0:
		seconds_per_day = new_seconds_per_day
	game_time = 0.0
	day = 0
	_resume_speed = Speed.NORMAL
	speed = -1  # force set_speed to emit so any UI resyncs
	set_speed(Speed.NORMAL)
