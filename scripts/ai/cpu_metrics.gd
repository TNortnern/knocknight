extends RefCounted
## Pacing / footwork measurements for a pair of fighters (used by tools/fight_stats.gd and tests/test_cpu_pacing.gd).
## Call sample(dt) once per physics tick while the bout is live. Preload it, don't reference by class name.

const DISENGAGE_WAIT := 1.5    ## s with no strike after a burst...
const DISENGAGE_MOVE := 0.5    ## ...in which the fighter walked at least this far = a "reset"
const BURST_LINK := 1.4        ## strikes closer together than this belong to one burst

var f: Array
var t := 0.0
var strikes := [0, 0]
var dist := [0.0, 0.0]
var lat := [0.0, 0.0]
var adv := [0.0, 0.0]          ## m walked toward / away from the foe
var ret := [0.0, 0.0]
var min_x := [99.0, 99.0]
var max_x := [-99.0, -99.0]
var min_z := [99.0, 99.0]
var max_z := [-99.0, -99.0]
var strike_gap_sum := [0.0, 0.0]
var combos := [0, 0]           ## bursts of 2-4 strikes followed by a disengagement
var bursts := [0, 0]
var burst_sizes := [[], []]
var _pace_cache := [[0, 0.0, 0], [0, 0.0, 0]]   ## [rest_strikes, rest_time, rest_cancels] copied by finish()
var _finished := false
var _prev_pos := [Vector3.ZERO, Vector3.ZERO]
var _serial := [0, 0]
var _last_strike_t := [-99.0, -99.0]
var _burst_n := [0, 0]
var _post_t := [-1.0, -1.0]      ## >= 0: time since the burst ended, waiting to see if it disengaged
var _post_dist := [0.0, 0.0]
var _post_n := [0, 0]


func _init(fighters: Array) -> void:
	f = fighters
	for i in 2:
		_prev_pos[i] = f[i].global_position
		_serial[i] = f[i]._serial


func sample(dt: float) -> void:
	t += dt
	for i in 2:
		var p: Vector3 = f[i].global_position
		var d: Vector3 = p - _prev_pos[i]
		d.y = 0.0
		_prev_pos[i] = p
		var u: Vector3 = f[i].dir_to_foe()
		var along := d.dot(u)
		dist[i] += d.length()
		lat[i] += (d - u * along).length()
		if along > 0.0:
			adv[i] += along
		else:
			ret[i] -= along
		min_x[i] = minf(min_x[i], p.x)
		max_x[i] = maxf(max_x[i], p.x)
		min_z[i] = minf(min_z[i], p.z)
		max_z[i] = maxf(max_z[i], p.z)
		var n: int = f[i]._serial - _serial[i]
		_serial[i] = f[i]._serial
		if n > 0:
			strikes[i] += n
			strike_gap_sum[i] += f[i].gap_to_foe() * n
			if t - _last_strike_t[i] > BURST_LINK:
				_end_burst(i)
				_burst_n[i] = 0
			_burst_n[i] += n
			_last_strike_t[i] = t
			_post_t[i] = -1.0
		elif _burst_n[i] > 0 and t - _last_strike_t[i] > BURST_LINK:
			_end_burst(i)   # burst is over; now watch the next DISENGAGE_WAIT s
			_post_t[i] = 0.0
			_post_dist[i] = 0.0
			_post_n[i] = _burst_n[i]
			_burst_n[i] = 0
		if _post_t[i] >= 0.0:
			_post_t[i] += dt
			_post_dist[i] += d.length()
			if _post_t[i] >= DISENGAGE_WAIT:
				if _post_n[i] >= 2 and _post_n[i] <= 4 and _post_dist[i] >= DISENGAGE_MOVE:
					combos[i] += 1
				_post_t[i] = -1.0


## Copy the brains' pacing counters (call before the fighters are freed).
func finish() -> void:
	for i in 2:
		var b = f[i]._brain
		_pace_cache[i] = [b.pace.rest_strikes, b.pace.rest_time, b.pace.rest_cancels] if (b != null and "pace" in b) else [0, 0.0, 0]
	_finished = true


func _end_burst(i: int) -> void:
	if _burst_n[i] > 0:
		bursts[i] += 1
		burst_sizes[i].append(_burst_n[i])


func per_min(i: int) -> float:
	return strikes[i] / maxf(t, 1.0) * 60.0


func lateral_share(i: int) -> float:
	return lat[i] / maxf(dist[i], 0.001)


func advance_share(i: int) -> float:
	return adv[i] / maxf(adv[i] + ret[i], 0.001)


func span(i: int) -> Vector2:
	return Vector2(max_x[i] - min_x[i], max_z[i] - min_z[i])


func mean_strike_gap(i: int) -> float:
	return strike_gap_sum[i] / maxf(strikes[i], 1)


func report(i: int) -> String:
	if not _finished:
		finish()
	var s := span(i)
	var pc: Array = _pace_cache[i]
	return "P%d moved %.0f m (%.2f m/s)  lateral %.0f%%  advance %.0f%%  ring span %.1f x %.1f m  strike gap %.2f m  bursts %d (avg %.1f strikes)  combos+reset %d  rest-strikes %d rest %.0f%% cancels %d" % [
		i + 1, dist[i], dist[i] / maxf(t, 1.0), lateral_share(i) * 100.0, advance_share(i) * 100.0, s.x, s.y, mean_strike_gap(i),
		bursts[i], float(strikes[i]) / maxf(bursts[i], 1), combos[i], pc[0], pc[1] / maxf(t, 1.0) * 100.0, pc[2]]
