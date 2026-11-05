# transit_router.gd
## Plans a passenger's journey across every line, including transfers.
##
## Build one per station arrival (the network is snapshotted in _init), then ask it
## about as many passengers as you like. Answers are cached per (station, target, line).
class_name TransitRouter
extends RefCounted

## Cost of riding one hop between two stations.
const STOP_COST := 1.0
## Extra cost for changing lines, so a slightly longer one-seat ride beats a transfer.
const TRANSFER_PENALTY := 3.0

var _edges: Dictionary = {}  # Area2D -> Array[{"to": Area2D, "line": MetroLine}]
var _cache: Dictionary = {}


func _init(tree: SceneTree) -> void:
	for node in tree.get_nodes_in_group("metro_lines"):
		var line := node as MetroLine
		if line == null or line.is_queued_for_deletion():
			continue
		var stops := line.connected_stations  # loops repeat the first station at the end
		for i in range(stops.size() - 1):
			var a: Area2D = stops[i]
			var b: Area2D = stops[i + 1]
			if a == b:
				continue
			_add_edge(a, b, line)
			if not line.is_loop:
				_add_edge(b, a, line)  # loop trains only ever run forward


## First leg of the cheapest journey from `from` to any station of `target_type`.
## `current_line` is the line the passenger is already sitting on (null if waiting),
## so staying put is never charged a transfer penalty.
##
## Returns {"line": MetroLine, "next": Area2D, "alight": Area2D} where `line` is the line
## to ride next, `next` is the very next station on it (which tells you which direction
## to travel), and `alight` is where that leg ends (a transfer station, or the destination).
## Returns {} if the target can't be reached.
func plan(from: Area2D, target_type: String, current_line: MetroLine = null) -> Dictionary:
	var cache_key := "%d|%s|%d" % [from.get_instance_id(), target_type, current_line.get_instance_id() if current_line else 0]
	if _cache.has(cache_key):
		return _cache[cache_key]
	var result := _search(from, target_type, current_line)
	_cache[cache_key] = result
	return result


func _add_edge(from: Area2D, to: Area2D, line: MetroLine) -> void:
	if not _edges.has(from):
		_edges[from] = []
	_edges[from].append({"to": to, "line": line})


func _state_key(station: Area2D, line: MetroLine) -> String:
	return "%d:%d" % [station.get_instance_id(), line.get_instance_id() if line else 0]


## Dijkstra over (station, line-you-arrived-on) states so transfers can be penalised.
## The graph is tiny, so a linear scan for the cheapest open state is plenty.
func _search(from: Area2D, target_type: String, current_line: MetroLine) -> Dictionary:
	var start := _state_key(from, current_line)
	var cost := {start: 0.0}
	var prev := {}
	var states := {start: [from, current_line]}  # key -> [station, line]
	var open: Array = [start]
	var goal = null

	while not open.is_empty():
		var best_i := 0
		for i in range(1, open.size()):
			if cost[open[i]] < cost[open[best_i]]:
				best_i = i
		var key: String = open[best_i]
		open.remove_at(best_i)

		var station: Area2D = states[key][0]
		var line: MetroLine = states[key][1]
		if key != start and station.type == target_type:
			goal = key
			break

		for edge in _edges.get(station, []):
			var next_line: MetroLine = edge["line"]
			var step := STOP_COST
			if line != null and next_line != line:
				step += TRANSFER_PENALTY
			var next_key := _state_key(edge["to"], next_line)
			var new_cost: float = cost[key] + step
			if not cost.has(next_key) or new_cost < cost[next_key]:
				cost[next_key] = new_cost
				prev[next_key] = key
				states[next_key] = [edge["to"], next_line]
				if not open.has(next_key):
					open.append(next_key)

	if goal == null:
		return {}

	# Walk back to the start, then read off the first leg
	var path: Array = []
	var k: String = goal
	while true:
		path.push_front(states[k])
		if k == start:
			break
		k = prev[k]

	var first_line: MetroLine = path[1][1]
	var alight: Area2D = path[1][0]
	for i in range(2, path.size()):
		if path[i][1] != first_line:
			break
		alight = path[i][0]
	return {"line": first_line, "next": path[1][0], "alight": alight}
