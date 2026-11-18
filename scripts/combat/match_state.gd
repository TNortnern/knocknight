class_name MatchState
extends RefCounted
## Round / timer / result bookkeeping, no nodes. Match drives it each physics tick.

enum Phase { PRE, FIGHT, ROUND_END, INTERMISSION, MATCH_END }

var round := 0
var rounds := 3
var round_seconds := 180.0
var timed := true
var time_left := 180.0
var phase: Phase = Phase.PRE
var phase_t := 0.0
var result: Dictionary = {}
var practice := false


func configure(p_rounds: int, p_seconds: float, p_practice: bool) -> void:
	rounds = clampi(p_rounds, 1, 5)
	round_seconds = p_seconds
	timed = p_seconds > 0.0
	practice = p_practice


func begin_round() -> void:
	round += 1
	time_left = round_seconds
	phase = Phase.FIGHT
	phase_t = 0.0


## Advance the clock. Returns true when time just ran out.
func tick(dt: float) -> bool:
	phase_t += dt
	if phase == Phase.FIGHT and timed:
		time_left = maxf(time_left - dt, 0.0)
		if time_left <= 0.0:
			return true
	return false


func is_last_round() -> bool:
	return round >= rounds


## Winner by the sum of the four max pools. Tie -> Draw (the Rust sim gave ties to P2; see deviations).
static func decide(stats0: FighterStats, stats1: FighterStats) -> Dictionary:
	var a := stats0.total_max()
	var b := stats1.total_max()
	if absf(a - b) < 0.01:
		return {"winner": -1, "method": "Draw", "scores": [a, b]}
	return {"winner": 0 if a > b else 1, "method": "Decision", "scores": [a, b]}
