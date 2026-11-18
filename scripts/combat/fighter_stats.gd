class_name FighterStats
extends RefCounted
const FatigueScript := preload("res://scripts/combat/fatigue.gd")
## Health pools, guard meter, stamina and rock bookkeeping for one fighter (spec section 5).

var head := 100.0
var head_max := 100.0
var body := 100.0
var body_max := 100.0
var lleg := 100.0
var lleg_max := 100.0
var rleg := 100.0
var rleg_max := 100.0
var guard := 100.0
var guard_max := 100.0
const STAMINA_CAP := 255.0   ## owner 2026-10-28: +30% across the board (was 196)
var stamina := STAMINA_CAP
var stamina_max := STAMINA_CAP

var rock_meter := 0.0
var rocked := false
var stun_left := 0.0
var knockdowns := 0
var regen_lock := 0.0
var guard_lock := 0.0
var guard_regen_lock := 0.0
var stamina_lock := 0.0
var infinite_stamina := false
var moving := false          ## set by the fighter every tick: walking / circling (regen is slower)
var busy := false            ## set by the fighter every tick: mid-strike (almost no regen)
var rock_grace := 0.0         ## s after a rock episode during which no new rock can start (the knockdown rules still apply)
var kd_grace := 0.0           ## s after a knockdown during which no further knockdown (power shot) can happen
var _kd_seen := 0
var kd_round_base := 0       ## knockdowns taken before this round started (TKO counts per round, see should_tko)
var wear := 0.0              ## stamina_max lost to accumulated rounds (rehab)
var practice := false
var mass := 1.0              ## body contact: push strength / weight class (roster.gd), Viper 0.9 .. Oak 1.3


func reset_for_bout() -> void:
	head = 100.0
	head_max = 100.0
	body = 100.0
	body_max = 100.0
	lleg = 100.0
	lleg_max = 100.0
	rleg = 100.0
	rleg_max = 100.0
	guard = guard_max
	stamina_max = STAMINA_CAP
	wear = 0.0
	stamina = stamina_max
	rock_meter = 0.0
	rocked = false
	stun_left = 0.0
	knockdowns = 0
	kd_round_base = 0
	kd_grace = 0.0
	_kd_seen = 0
	regen_lock = 0.0
	guard_lock = 0.0
	guard_regen_lock = 0.0
	stamina_lock = 0.0


## Between rounds: max = min(current + 30, 100), stamina refilled, guard +30.
func rehab() -> void:
	head_max = minf(head + 30.0, 100.0)
	head = minf(head, head_max)
	body_max = minf(body + 30.0, 100.0)
	body = minf(body, body_max)
	lleg_max = minf(lleg + 30.0, 100.0)
	lleg = minf(lleg, lleg_max)
	rleg_max = minf(rleg + 30.0, 100.0)
	rleg = minf(rleg, rleg_max)
	# fatigue pass: every round leaves some wear (the pool the fighter can recover to shrinks by ROUND_WEAR) and the
	# minute's rest only refills ROUND_RECOVERY of what was spent, so round 3 is a tired round.
	kd_round_base = knockdowns
	wear = minf(wear + ROUND_WEAR, 60.0)
	stamina_max = minf(stamina_max + 30.0, STAMINA_CAP - wear)
	stamina = minf(stamina + (stamina_max - stamina) * ROUND_RECOVERY, stamina_max)
	guard = minf(guard + 30.0, guard_max)
	rock_meter = 0.0
	rocked = false
	stun_left = 0.0


const KD_GRACE := 12.0
const TKO_PER_ROUND := 3        ## knockdowns in one round that stop the fight
const TKO_PER_BOUT := 4         ## ... or in the whole bout (spec: 3 in the bout)

## True when the knockdown about to be scored is the one that ends the fight (fatigue pass: was `knockdowns >= 2` per bout).
func should_tko() -> bool:
	return knockdowns - kd_round_base >= TKO_PER_ROUND - 1 or knockdowns >= TKO_PER_BOUT - 1


const HEAD_MAX_EROSION := 0.4   ## share of the spec's permanent head damage that sticks (the rest heals back)
const ROUND_WEAR := 10.0
const ROUND_RECOVERY := 0.75


## 0..1 tiredness (see fatigue.gd); 0 for infinite stamina.
func fatigue() -> float:
	return 0.0 if infinite_stamina else FatigueScript.level(stamina_ratio())


func total_max() -> float:
	return head_max + body_max + lleg_max + rleg_max


func is_ko() -> bool:
	return head_max <= 0.0 or body_max <= 0.0 or lleg_max <= 0.0 or rleg_max <= 0.0


func stamina_ratio() -> float:
	return stamina / maxf(stamina_max, 1.0)


func can_spend(cost: float) -> bool:
	return infinite_stamina or (stamina >= 10.0 and stamina >= cost)


func spend_stamina(cost: float, lock := 0.25) -> void:
	if infinite_stamina:
		return
	stamina = maxf(stamina - cost, 0.0)
	stamina_lock = maxf(stamina_lock, lock * (1.0 + 0.8 * fatigue()))   # tired: regen resumes later


## head -= total, head_max -= bonus (+0.25 num if already rocked). head_max never drops below 1 here;
## the caller decides when a head KO (head_max -> 0) happens.
func apply_head(total: float, bonus: float, num: float) -> void:
	head -= total
	head_max = maxf(head_max - HEAD_MAX_EROSION * (bonus + (0.25 * num if rocked else 0.0)), 1.0)   # fatigue pass: permanent damage was ~100 per 3 min round
	head = clampf(head, 0.0, head_max)


func apply_body(total: float, bonus: float) -> void:
	body_max -= bonus
	body = clampf(body - total, 0.0, maxf(body_max, 0.0))
	stamina_max = maxf(stamina_max - 0.1 * total, 10.0)
	stamina = minf(stamina, stamina_max)


func apply_leg(left: bool, total: float) -> void:
	if left:
		lleg_max -= total
		lleg = clampf(lleg - total, 0.0, maxf(lleg_max, 0.0))
	else:
		rleg_max -= total
		rleg = clampf(rleg - total, 0.0, maxf(rleg_max, 0.0))


func tick(dt: float, guarding: bool, low_regen: bool) -> void:
	regen_lock = maxf(regen_lock - dt, 0.0)
	guard_lock = maxf(guard_lock - dt, 0.0)
	guard_regen_lock = maxf(guard_regen_lock - dt, 0.0)
	stamina_lock = maxf(stamina_lock - dt, 0.0)
	if knockdowns != _kd_seen:
		_kd_seen = knockdowns
		kd_grace = KD_GRACE if knockdowns > 0 else 0.0
	kd_grace = maxf(kd_grace - dt, 0.0)
	if infinite_stamina:
		stamina = stamina_max
	elif stamina_lock <= 0.0:
		var rate := CombatRules.STAMINA_REGEN
		if guarding or low_regen:
			rate = CombatRules.STAMINA_REGEN_GUARD
		elif busy:
			rate = CombatRules.STAMINA_REGEN_BUSY
		elif moving:
			rate = CombatRules.STAMINA_REGEN_MOVE
		stamina = minf(stamina + rate * dt, stamina_max)
	if not guarding and guard_regen_lock <= 0.0:
		guard = minf(guard + CombatRules.GUARD_REGEN * dt, guard_max)
	if rocked:
		stun_left -= dt
		if stun_left <= 0.0:
			rocked = false
			stun_left = 0.0
			rock_grace = CombatRules.ROCK_GRACE
	else:
		rock_grace = maxf(rock_grace - dt, 0.0)
		rock_meter = maxf(rock_meter - CombatRules.ROCK_METER_DECAY * dt, 0.0)
	if regen_lock <= 0.0 and not rocked:
		var r := CombatRules.HEALTH_REGEN * dt
		head = minf(head + r, head_max)
		body = minf(body + r, maxf(body_max, 0.0))
		lleg = minf(lleg + r, maxf(lleg_max, 0.0))
		rleg = minf(rleg + r, maxf(rleg_max, 0.0))
	if practice:
		head_max = 100.0
		body_max = 100.0
		lleg_max = 100.0
		rleg_max = 100.0
		head = clampf(head + 24.0 * dt, 35.0, 100.0)
		body = clampf(body + 24.0 * dt, 35.0, 100.0)
		lleg = clampf(lleg + 24.0 * dt, 35.0, 100.0)
		rleg = clampf(rleg + 24.0 * dt, 35.0, 100.0)
