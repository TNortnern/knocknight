extends RefCounted
## Timing and per-episode randomisation of the "hurt" states of one fighter (pure logic, no nodes).
##
##   HEAD  (rocked): DAZE (no offence, half-speed shuffle, gloves at the belt) -> TAIL (guard returns over
##                   GUARD_RETURN s, three-quarter speed, still vulnerable). Whole episode = stats.rocked.
##   BODY  (hurt_body): short waist fold with a knee dip, hand clutching the liver side, slow movement.
##
## Reference: Undisputed rocked fighter (7:07 of youtu.be/SrTtLQLByhw) and docs/handoff86/design-rocked.json.

enum Kind { NONE, HEAD, BODY }

const ONSET := 0.30                 ## s the pose layer takes to fade in after the hit (the hit clip covers it)
const DAZE_BASE := 1.2              ## daze = 1.2 + 0.6 x severity -> 1.41 .. 1.8 s
const DAZE_PER_SEV := 0.6
const TAIL_BASE := 1.0              ## vulnerable tail with the guard coming back: 1.0 + 0.8 x severity
const TAIL_PER_SEV := 0.8
const GUARD_RETURN := 0.35          ## s over which the gloves come back up at the end of the daze
const MAX_TOTAL := 4.2
const DAZE_MOVE := 0.5              ## half-speed shuffle
const TAIL_MOVE := 0.75
const BODY_MOVE := 0.4
const DAZE_BLOCK_WEAKNESS := 1.8    ## guard-meter loss multiplier when a dazed fighter holds block
const DAZE_CHIP_MULT := 2.0
const BODY_BASE := 0.70             ## body hurt = 0.7 + 0.5 x severity -> 0.85 .. 1.2 s
const BODY_PER_SEV := 0.5
const BODY_DAMAGE := 8.0            ## unblocked body shot trigger
const BODY_COUNTER_DAMAGE := 6.0
const BODY_RATIO := 0.40            ## or body health ratio below this
const BODY_COOLDOWN := 3.5          ## s after a body fold before the next one can trigger

var kind := Kind.NONE
var t := 0.0                        ## seconds since the episode started
var severity := 0.0
var daze_len := 0.0
var tail_len := 0.0
var body_len := 0.0
var cooldown := 0.0
var side := 0.0                     ## +1 = hit on the fighter's left flank, -1 right, 0 front/centre
var guard_up := false               ## set by the fighter every tick: block held
var suppress := false               ## set by the fighter: knocked down / KO'd / victory, the pose layer lets go
var episode := 0                    ## increments per episode (decorrelates the random streams)

# per-episode random look (so two rocked fighters never move identically)
var sway_sign := 1.0                ## which way the trunk leans/sways first
var sway_amp := 1.0                 ## 0.8 .. 1.25
var sway_freq := 1.0                ## 0.85 .. 1.2
var sway_phase := 0.0
var chin_amp := 1.0
var glove_asym := 0.0               ## -1..1: which glove sits lower
var catch_t := 0.4                  ## seconds until the next stumble impulse
var catch_gap_scale := 1.0


func active() -> bool:
	return kind != Kind.NONE


func is_head() -> bool:
	return kind == Kind.HEAD


func is_body() -> bool:
	return kind == Kind.BODY


## Head daze phase: no strikes, half speed, gloves down.
func dazed() -> bool:
	return kind == Kind.HEAD and t < daze_len


## Anything that forbids throwing strikes.
func offence_locked() -> bool:
	return (kind == Kind.HEAD and t < daze_len) or (kind == Kind.BODY and t < body_len)


func total_len() -> float:
	return daze_len + tail_len if kind == Kind.HEAD else (body_len if kind == Kind.BODY else 0.0)


func remaining() -> float:
	return maxf(total_len() - t, 0.0)


func move_scale() -> float:
	match kind:
		Kind.HEAD:
			return DAZE_MOVE if t < daze_len else TAIL_MOVE
		Kind.BODY:
			return BODY_MOVE
	return 1.0


## Guard-meter / chip multiplier while a dazed fighter holds block (weak block).
func block_weakness() -> float:
	return DAZE_BLOCK_WEAKNESS if dazed() else 1.0


## 0 during the daze, 0 -> 1 over GUARD_RETURN after it ends (smoothstep).
func guard_return() -> float:
	if kind != Kind.HEAD or t < daze_len:
		return 0.0
	return smoothstep(0.0, 1.0, clampf((t - daze_len) / GUARD_RETURN, 0.0, 1.0))


## 0 -> 1 fade-in of the pose layer after the hit.
func onset() -> float:
	return smoothstep(0.0, 1.0, clampf(t / ONSET, 0.0, 1.0))


func clear() -> void:
	kind = Kind.NONE
	t = 0.0
	severity = 0.0
	daze_len = 0.0
	tail_len = 0.0
	body_len = 0.0
	side = 0.0


func _roll(rng: RandomNumberGenerator) -> void:
	episode += 1
	sway_sign = 1.0 if rng.randf() < 0.5 else -1.0
	sway_amp = rng.randf_range(0.8, 1.25)
	sway_freq = rng.randf_range(0.85, 1.2)
	sway_phase = rng.randf() * TAU
	chin_amp = rng.randf_range(0.8, 1.2)
	glove_asym = rng.randf_range(-1.0, 1.0)
	catch_gap_scale = rng.randf_range(0.8, 1.3)
	catch_t = rng.randf_range(0.25, 0.55)


static func daze_for(sev: float) -> float:
	return DAZE_BASE + DAZE_PER_SEV * clampf(sev, 0.0, 1.0)


static func tail_for(sev: float) -> float:
	return TAIL_BASE + TAIL_PER_SEV * clampf(sev, 0.0, 1.0)


static func body_for(sev: float) -> float:
	return BODY_BASE + BODY_PER_SEV * clampf(sev, 0.0, 1.0)


func start_head(sev: float, rng: RandomNumberGenerator) -> void:
	_roll(rng)
	kind = Kind.HEAD
	t = 0.0
	severity = clampf(sev, 0.0, 1.0)
	daze_len = daze_for(severity)
	tail_len = tail_for(severity)
	body_len = 0.0
	side = 0.0


## `left_flank`: the shot landed on the fighter's left side (fighter-left is +x).
func start_body(sev: float, left_flank: bool, centre: bool, rng: RandomNumberGenerator) -> void:
	_roll(rng)
	kind = Kind.BODY
	t = 0.0
	severity = clampf(sev, 0.0, 1.0)
	body_len = body_for(severity)
	daze_len = 0.0
	tail_len = 0.0
	side = 0.0 if centre else (1.0 if left_flank else -1.0)
	cooldown = BODY_COOLDOWN


## Body severity from the hit damage and the remaining body health ratio.
static func body_severity(total: float, ratio: float) -> float:
	return clampf(total / 18.0 + (1.0 - ratio) * 0.5, 0.3, 1.0)


## Should an unblocked body hit of `total` damage fold the fighter?
func body_trigger(total: float, ratio: float, counter: bool) -> bool:
	if cooldown > 0.0 or kind == Kind.HEAD:
		return false
	if kind == Kind.BODY and t < body_len:
		return false
	return total >= BODY_DAMAGE or (counter and total >= BODY_COUNTER_DAMAGE) or ratio <= BODY_RATIO


## A hard hit while already rocked lengthens the tail (the daze itself is never extended).
func extend(seconds: float) -> void:
	if kind == Kind.HEAD:
		tail_len = minf(tail_len + seconds, MAX_TOTAL - daze_len)


func tick(dt: float) -> void:
	cooldown = maxf(cooldown - dt, 0.0)
	if kind == Kind.NONE:
		return
	t += dt
	if t >= total_len():
		clear()
