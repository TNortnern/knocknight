extends RefCounted
## CPU pacing: strikes come in bursts of 2-4 (a combo or two), then the CPU RESETS for a few seconds (footwork, feints, a
## paw of the jab, guard) before the next burst. Rest length depends on difficulty, style, stamina and the round opening
## (the first seconds of a round are a feeling-out period: longer rests, 1-2 strike bursts). A rocked / gassed foe cancels
## the rest (the CPU presses). Strikes thrown DURING a rest (counters, return jabs, paws) do not start a burst.
## Preload it; one instance per brain (CpuBrain.pace).

const OPENING_FIRST := 13.0    ## s of feeling-out at the start of the first round
const OPENING_LATER := 5.0     ## ...and of later rounds
## Resets between bursts. The owner's references (Fight Night, Tale of the Tape) keep the fighters engaged: shorter resets,
## then the next exchange (was 4.8-10 s, CPUs rested ~75% of a round; 3-6.5 s with the faster punches ran ~35 strikes/min;
## 3.8-8 s with the held, eased punches emptied the tank below 35% in 5 of 8 round-1 bouts).
const REST_MIN := 4.3
const REST_MAX := 9.0
const EXCHANGE := 0.25         ## chance to keep trading when a burst ends with the foe still throwing
const OPENING_REST := 2.1      ## rest x during the opening

var resting := true
var rest_t := 0.0
var opening := OPENING_FIRST
var burst_n := 0
var burst_goal := 2
var idle_t := 0.0
var just_rested := false     ## true for one tick after a burst ended (footwork steps out)
var exchanges := 0           ## stats
var bursts := 0              ## stats
var rest_time := 0.0         ## stats
var rest_cancels := 0
var rest_strikes := 0        ## stats: strikes thrown while resting (counters, return jabs, paws)
var _serial := -1


func on_round_start(b, full: bool) -> void:
	opening = OPENING_FIRST if full else OPENING_LATER
	burst_n = 0
	idle_t = 0.0
	_start_rest(b, false)


func cancel_rest() -> void:
	if resting:
		rest_cancels += 1
	resting = false
	burst_n = 0
	idle_t = 0.0


func _goal(b) -> int:
	var pool: Array = b.style["burst"]
	var n: int = pool[b.rng.randi() % pool.size()]
	return mini(n, 2) if opening > 0.0 else n


## An exchange: the burst ended while the foe is still throwing and we are fresh, so keep trading for a couple more
## punches instead of resetting. These sustained exchanges are where rocks, knockdowns and gassing come from.
func _exchange(b) -> bool:
	if opening > 0.0 or b.f.stats.stamina_ratio() < 0.8 or b._foe_active_t <= 0.0 or b.f.foe.stats.stamina_ratio() < 0.35:
		return false
	return b.rng.randf() < EXCHANGE

func _start_rest(b, after_burst: bool) -> void:
	if after_burst and _exchange(b):
		exchanges += 1
		burst_goal = burst_n + b.rng.randi_range(2, 3)
		return
	resting = true
	just_rested = after_burst
	var stam: float = b.f.stats.stamina_ratio()
	var r: float = b.rng.randf_range(REST_MIN, REST_MAX) * float(b.style["rest"]) * float(b.diff["rest"])
	r *= 1.0 + clampf(0.8 - stam, 0.0, 1.0) * 2.6          # tired: breathe longer
	if opening > 0.0:
		r *= OPENING_REST
	if after_burst:
		bursts += 1
	rest_t = r
	burst_n = 0
	burst_goal = _goal(b)


func update(b, dt: float) -> void:
	just_rested = false
	opening = maxf(opening - dt, 0.0)
	var f = b.f
	var n: int = 0 if _serial < 0 else f._serial - _serial
	_serial = f._serial
	if resting:
		rest_strikes += maxi(n, 0)
		rest_time += dt
		rest_t -= dt
		if rest_t <= 0.0:
			resting = false
			burst_n = 0
			idle_t = 0.0
		return
	if n > 0:
		burst_n += n
		idle_t = 0.0
	elif f.state == Fighter.State.IDLE and b._combo.is_empty():
		idle_t += dt
	if burst_n > 0 and idle_t > 4.5:
		burst_n = 0                  # stale burst: start counting afresh
		burst_goal = _goal(b)
	if b.f.stats.stamina_ratio() < 0.62:
		burst_goal = mini(burst_goal, 2)   # winded: one short burst, then breathe
	if burst_n >= burst_goal and b._combo.is_empty() and f.state == Fighter.State.IDLE:
		_start_rest(b, true)
