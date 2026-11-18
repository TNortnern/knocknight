extends RefCounted
## Body-to-body contact (one instance per fighter, `Fighter.bc`). Preload it: `const BodyContactScript := preload(...)`.
##
## Real boxing, tuned for feel. When the torsos (the hulls fitted to the visible body, HitAreas.contact_gap) actually touch (<= 1 cm) the pair is "in contact":
##   * force balance: each fighter pushes with  mass x drive x stamina factor  (drive = how hard he walks into the foe).
##     The pair then moves as one body along the line of centres: the stronger pusher drives both back, equal pushes
##     stall, a passive fighter plants his feet (PLANT) but still gives ground to a heavier man. The ring walls stop
##     whoever is driven into them (the pusher then simply stops against him).
##   * leaning costs stamina (pusher a little, the pressed fighter more, more again when pinned or tired).
##   * shove-off (FighterInput.shove): a two-hand / shoulder push that opens 0.4-0.6 m (strength difference), costs
##     stamina, leaves the shover recovering for SHOVE_LOCK and the shoved fighter off balance (no punch for
##     SHOVED_NO_PUNCH, guard locked, `off_balance()` for _balance()). Into the ropes it opens less and rebounds.
##   * referee break: both pressing (or one pinned on the ropes and leaned on) for BREAK_AFTER without a punch ->
##     the pair is walked apart to BREAK_GAP (smooth, no teleport) and the Match shows "BREAK".
##   * smother_factor(): long punches inside contact range are smothered (damage multiplier for CombatRules).
## The look of all this (lean, head to the side, shove arms, torso snap) is scripts/fighter/contact_pose.gd, which only reads
## the fields below.

signal referee_break

const TORSO_OVERLAP_CHECK := 0.50   ## root distance below which the torso hulls are tested for overlap (corners / ropes squeeze a pinned fighter)
const TORSO_CHECK := 0.62       ## root-to-root distance beyond which the bodies cannot touch (no hull test)
const TORSO_RELEASE := 0.05     ## m: a pair in contact stays in contact until the torsos are this far apart (no flicker); fresh contact needs a real touch (HitAreas.TORSO_TOUCH)
const CONTACT_FLOOR := 0.42     ## root-to-root distance the pressing pair settles at: the lead glove / forearm resting on the foe's chest (glove reach ~0.3 + torso front ~0.1, a little less than the sum: the presser leans in).
const PRESS_HOLD_GAP := 0.10    ## m: a driver pressing at the floor keeps the contact while the gloves sway off the hull, up to this far (test_hit_contact: never in contact > 12 cm apart)
                                ## A fixed number on purpose: the arm poses react to contact, a floor measured on the volumes would oscillate. The bodies touch there
const SHOVE_TORSO_GAP := 0.06   ## a shove can start a touch before full contact (torso hulls this close)
const WALK := 0.9               ## m/s of intended speed into the foe that counts as full drive
const PLANT := 0.6              ## a passive fighter resists with this fraction of his mass
const BREAK_AFTER := 2.5        ## s of locked contact (no punches) before the referee steps in
const BREAK_GAP := 1.2
const BREAK_SPEED := 0.75       ## m/s each fighter backs away during a break
const BREAK_MAX := 1.4
const SHOVE_COST := 9.0
const SHOVE_COOLDOWN := 1.1
const SHOVE_LOCK := 0.38        ## s the shover cannot punch
const SHOVED_NO_PUNCH := 0.28   ## s the shoved fighter cannot punch (the owner's number: ~0.25 s)
const SHOVED_OFF_BALANCE := 0.6
const TURN_RANGE := 0.80
const TURN_DAMP := 0.85          ## fraction of the relative sideways (orbiting) speed removed in chest contact
const BUMP_MIN := 1.0           ## m/s closing speed (both fighters, incl. entry steps) that makes fresh contact a bump
const BUMP_MIN_WHIFF := 0.5     ## ... when the driver is mid-punch and has missed (he is overextended)
const BUMP_TIME := 0.24         ## s the stopped driver cannot walk on
const BUMP_COOLDOWN := 0.6
const STUMBLE_NO_PUNCH := 0.22
const RESTITUTION := 0.3
const FRAME_EXTRA := 0.05       ## m a lead-forearm frame adds to the chest-to-chest root gap
const FRAME_COST := 0.8         ## stamina / s while framing
const WALL := 2.9               ## root stops here against the ropes (arena.gd)

## Shared by both fighters of a pair.
class Pair:
	extends RefCounted
	var frame := -1
	var lock_t := 0.0
	var break_t := 0.0
	var break_el := 0.0
	var break_cd := 0.0
	var side := 1.0             ## which way both heads go while pressing (fighter frame, same for both = opposite in the world)
	var contact_t := 0.0
	var active := false
	var bump_cd := 0.0
	var press_cd := 0.0          ## s: kept topped up while in contact: a re-touch of a pair that was just touching is a press, not a bump
	var adv := 0.0              ## head-position battle: + = fighter 0 of the pair holds the inside position
	var phase := 0.0
	var tgap := 9.0             ## shortest distance between the two bodies (HitAreas.contact_gap) this frame (m)
	var torso_gap := 9.0        ## shortest distance between the two torso hulls (m), computed when the roots are close: < 0 = the torsos overlap
	var tgap_s := 9.0           ## ... smoothed (the arms jitter: the pair solver and the release use this one)


var f: Node3D                   ## the Fighter
var pair: Pair

# --- read by contact_pose.gd / the HUD / tests
var in_contact := false
var contact_t := 0.0            ## s of continuous contact
var contact_w := 0.0            ## 0..1 smoothed contact weight
var drive := 0.0                ## 0..1 how hard this fighter walks into the foe
var press_w := 0.0              ## 0..1 leaning into the foe (pose)
var pressed_w := 0.0            ## 0..1 being driven back / leaned on (pose)
var pinned := false             ## back on the ropes with the foe in contact
var shove_t := 0.0              ## > 0 while shoving (SHOVE_LOCK down to 0)
var stagger_t := 0.0            ## > 0 while knocked off balance by a shove
var no_punch_t := 0.0
var shove_cd := 0.0
var kick := 0.0                 ## one-shot torso impulse for the pose spring (+ forward / - back), consumed by the pose
var last_vc := 0.0              ## last solved pair velocity along the line of centres (diagnostics)
var shoves_thrown := 0
var breaks := 0
var bump_t := 0.0               ## > 0 while a stopped driver cannot walk on
var stumble_t := 0.0            ## > 0 while stumbling into the foe after an overextended miss (chest to chest, head on his shoulder)
var bump_hit_t := 0.0           ## > 0 for a moment after being bumped (guard jolt, pose)
var bumps := 0                  ## bumps this fighter drove (diagnostics)
var frame_w := 0.0              ## 0..1 lead forearm on the foe's chest / shoulder (keeps space)
var frame_hold := 0.0           ## s left of a requested frame (the CPU sets it, a blocking human frames automatically)
var head_push := 0.0            ## 0..1 the CPU / player is fighting for the inside position (adds to the head battle)
var inside_pos := 0.0           ## -1..1 head-position battle (+ = holds the inside: head beside the foe's, better short punches)
var extra := Vector3.ZERO       ## entry-step velocity of this frame (set by Fighter._apply_movement)
var correction := Vector3.ZERO  ## velocity correction for this physics frame (read through move_correction())
var _corr_frame := -1
var side_sign := 1.0
var _rebound := 0.0
var _rebound_t := 0.0
var _rebound_dir := Vector3.ZERO


# ------------------------------------------------------------------ pure rules (also used by tests / the CPU)
static func mass_of(fighter: Object) -> float:
	var m: Object = fighter.stats
	return float(m.mass)


## 0.6 (empty) .. 1.0 (half tank or better).
static func stamina_factor(fighter: Object) -> float:
	var r := float(fighter.stats.stamina_ratio())
	return lerpf(0.6, 1.0, clampf(r / 0.5, 0.0, 1.0))


static func strength(fighter: Object) -> float:
	return mass_of(fighter) * stamina_factor(fighter)


## Space a shove by `a` opens against `b` (m): 0.4 .. 0.6 by strength difference, less against a man leaning hard.
static func shove_distance(a: Object, b: Object, b_drive := 0.0) -> float:
	var sa := strength(a)
	var sb := strength(b)
	var r := (sa - sb) / maxf(sa + sb, 0.01)
	return clampf((0.5 + 0.55 * r) * (1.0 - 0.15 * b_drive), 0.4, 0.6)


## Damage multiplier for a punch landed at root distance `gap` (1 = unaffected). Short punches (uppercuts, short / tight
## hooks, body shots) work in close; straights and wide looping shots are smothered.
## Only counts once the pair has been in contact for a moment (`contact_t`): a punch that steps in from range lands
## clean, one thrown from chest contact is smothered.
static func smother_factor(s: Dictionary, gap: float, contact_t := 0.0) -> float:
	var k := clampf((0.84 - gap) / 0.12, 0.0, 1.0) * smoothstep(0.1, 0.4, contact_t)
	if k <= 0.0:
		return 1.0
	return lerpf(1.0, _type_factor(s), k)


static func _type_factor(s: Dictionary) -> float:
	var tag := String(s.get("tag", ""))
	var klass := String(s.get("klass", "std"))
	if bool(s.get("is_leg", false)) or String(s.get("source", "hand")) == "leg":
		return 0.40
	if tag.contains("Uppercut"):
		return 0.95 if klass == "rise" else 1.0
	if tag.contains("OverHand") or tag.contains("BackFist"):
		return 0.5
	if String(s.get("zone", "head")) == "body":
		return 0.92 if (tag.contains("Hook") or tag.contains("Jab")) else 0.85
	if tag.contains("Hook"):
		match klass:
			"tight":
				return 0.90
			"wide":
				return 0.55
			"lunge", "power":
				return 0.60
		return 0.75
	# straights
	match klass:
		"flick":
			return 0.72
		"lunge", "power":
			return 0.45
		"pull":
			return 0.52
	return 0.58


# ------------------------------------------------------------------ per physics frame
func off_balance() -> bool:
	return stagger_t > 0.0


## Hit code / begin_attack ask this: a shoved fighter, a shover recovering and a referee break all forbid punching.
func blocks_offence() -> bool:
	return no_punch_t > 0.0 or shove_t > 0.0 or (pair != null and pair.break_t > 0.0)


func reset() -> void:
	in_contact = false
	contact_t = 0.0
	contact_w = 0.0
	drive = 0.0
	press_w = 0.0
	pressed_w = 0.0
	pinned = false
	shove_t = 0.0
	stagger_t = 0.0
	no_punch_t = 0.0
	bump_t = 0.0
	stumble_t = 0.0
	bump_hit_t = 0.0
	frame_w = 0.0
	frame_hold = 0.0
	head_push = 0.0
	inside_pos = 0.0
	correction = Vector3.ZERO
	_rebound_t = 0.0
	if pair != null:
		pair.lock_t = 0.0
		pair.break_t = 0.0
		pair.contact_t = 0.0
		pair.active = false
		pair.tgap_s = 9.0


func _standing(x: Node3D) -> bool:
	return not (x.is_acute_down() or x.is_out() or x.state == x.State.DOWN or x._ragdoll.active)


## Called at the top of Fighter._apply_movement (after locomotion has set `velocity`).
func step(dt: float, extra_v := Vector3.ZERO) -> void:
	extra = extra_v
	bump_t = maxf(bump_t - dt, 0.0)
	stumble_t = maxf(stumble_t - dt, 0.0)
	bump_hit_t = maxf(bump_hit_t - dt, 0.0)
	frame_hold = maxf(frame_hold - dt, 0.0)
	shove_t = maxf(shove_t - dt, 0.0)
	stagger_t = maxf(stagger_t - dt, 0.0)
	no_punch_t = maxf(no_punch_t - dt, 0.0)
	shove_cd = maxf(shove_cd - dt, 0.0)
	_tick_rebound(dt)
	var foe: Node3D = f.foe
	if foe == null or foe.bc == null:
		_idle(dt)
		return
	if pair == null:
		pair = foe.bc.pair if foe.bc.pair != null else Pair.new()
		foe.bc.pair = pair
		if foe.bc.pair != pair:
			foe.bc.pair = pair
	var frame := Engine.get_physics_frames()
	if pair.frame != frame:
		pair.frame = frame
		_resolve_pair(f, foe, dt)
	_after_resolve(dt)
	_update_frame(dt)
	_spacing_spring(foe)
	if f.inp != null and f.inp.shove:
		try_shove()


## Velocity change Fighter._apply_movement adds this frame (zero when the pair was not resolved this frame).
func move_correction() -> Vector3:
	return correction if _corr_frame == Engine.get_physics_frames() else Vector3.ZERO


func _idle(dt: float) -> void:
	in_contact = false
	contact_w = lerpf(contact_w, 0.0, 1.0 - exp(-8.0 * dt))
	press_w = lerpf(press_w, 0.0, 1.0 - exp(-8.0 * dt))
	pressed_w = lerpf(pressed_w, 0.0, 1.0 - exp(-8.0 * dt))


## The BODY_SPACING spring: closer than the capsule floor the foe is eased out (his own move_and_slide applies it).
func _spacing_spring(foe: Node3D) -> void:
	if not _standing(foe):
		return
	var d: Vector3 = foe.global_position - f.global_position
	d.y = 0
	if d.length() > 0.001:
		var to_foe: Vector3 = d.normalized()
		var k := 8.0
		var over := 0.0
		if d.length() < f.BODY_SPACING:
			over = f.BODY_SPACING - d.length()
		if pair != null and pair.torso_gap < -0.02 and -0.02 - pair.torso_gap > over:
			over = -0.02 - pair.torso_gap   # the torsos overlap (a pinned fighter in a corner under pressure): eased apart, gently (_push accumulates every frame)
			k = 3.0
		if over > 0.0:
			foe._push += to_foe * minf(over * k, 0.5)
			foe._push = foe._push.limit_length(6.0)


func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


func _resolve_pair(a: Node3D, b: Node3D, dt: float) -> void:
	var pa: Object = a.bc
	var pb: Object = b.bc
	var both_up: bool = _standing(a) and _standing(b)
	var d: Vector3 = _flat(b.global_position - a.global_position)
	var gap: float = d.length()
	var u: Vector3 = d / gap if gap > 0.001 else a.global_basis.z
	var tg := 9.0
	if both_up and gap < TORSO_CHECK:
		tg = HitAreas.contact_gap(a, b)   # the visible bodies (torsos, heads, arms), not the root distance
	pair.tgap = tg
	pair.torso_gap = HitAreas.torso_gap(a, b) if (both_up and gap < TORSO_OVERLAP_CHECK) else 9.0
	pair.tgap_s = tg if (pair.tgap_s > 5.0 or tg > 5.0) else lerpf(pair.tgap_s, tg, 1.0 - exp(-14.0 * dt))
	var tgs: float = pair.tgap_s
	# a pair held at the floor by a driver stays in contact while the gloves sway off the hull: releasing there let the driver walk on in
	# (no floor without contact) down to a torso overlap, contact came back and shoved the pair out to the floor again (a ~1.5 s in-out cycle)
	var pressing: bool = pair.active and gap < CONTACT_FLOOR + 0.06 and tg < PRESS_HOLD_GAP and maxf(pa.drive, pb.drive) > 0.3
	var active: bool = both_up and (tg <= HitAreas.TORSO_TOUCH or (pair.active and (tgs <= HitAreas.TORSO_TOUCH + TORSO_RELEASE or pressing)))
	pair.active = active
	pair.contact_t = pair.contact_t + dt if active else (0.0 if tg > 0.15 or not both_up else maxf(pair.contact_t - dt * 2.0, 0.0))
	if active and pair.contact_t <= dt * 1.5:   # a new contact episode: both heads go to the same fighter-side (= opposite world sides)
		pair.side = 1.0 if (Engine.get_physics_frames() / 7) % 2 == 0 else -1.0
	pa.side_sign = pair.side
	pb.side_sign = pair.side
	pa.in_contact = active
	pb.in_contact = active
	pa.contact_t = pair.contact_t
	pb.contact_t = pair.contact_t
	pa.correction = Vector3.ZERO
	pb.correction = Vector3.ZERO
	pa._corr_frame = Engine.get_physics_frames()
	pb._corr_frame = pa._corr_frame
	pair.break_cd = maxf(pair.break_cd - dt, 0.0)
	var wa: float = _flat(a.velocity).dot(u)         # intended speed towards the foe
	var wb: float = -_flat(b.velocity).dot(u)
	pa.drive = clampf(wa / WALK, 0.0, 1.0) if active else 0.0
	pb.drive = clampf(wb / WALK, 0.0, 1.0) if active else 0.0
	pa.last_vc = 0.0
	pb.last_vc = 0.0
	pa.pinned = false
	pb.pinned = false
	_head_battle(pa, pb, a, b, active, dt)
	# ---- bump: running / stepping into the foe at speed. Momentum by mass, the driver stops and stumbles
	pair.bump_cd = maxf(pair.bump_cd - dt, 0.0)
	pair.press_cd = maxf(pair.press_cd - dt, 0.0)
	var over_a: bool = a.state == a.State.ATTACK and not a.atk.is_empty() and String(a.atk.get("outcome", "")) == "missed"
	var over_b: bool = b.state == b.State.ATTACK and not b.atk.is_empty() and String(b.atk.get("outcome", "")) == "missed"
	# an entry step counts only once the punch has missed (a punch stepping in to land is not a collision)
	var cva: Vector3 = _flat(a.velocity) + (pa.extra if (over_a or a.state != a.State.ATTACK) else Vector3.ZERO)
	var cvb: Vector3 = _flat(b.velocity) + (pb.extra if (over_b or b.state != b.State.ATTACK) else Vector3.ZERO)
	var ca: float = cva.dot(u)
	var cb: float = -cvb.dot(u)
	if both_up and tg <= HitAreas.TORSO_TOUCH + 0.02 and pair.bump_cd <= 0.0 and pair.break_t <= 0.0 and ((pair.contact_t < 0.35 and pair.press_cd <= 0.0) or over_a or over_b):   # a missed punch carries the driver in even from a touch
		var thr_a: float = BUMP_MIN_WHIFF if over_a else BUMP_MIN
		var thr_b: float = BUMP_MIN_WHIFF if over_b else BUMP_MIN
		if ca >= thr_a or cb >= thr_b:
			_do_bump(a, b, pa, pb, u, ca, cb, over_a, over_b)
	if active:
		pair.press_cd = BUMP_COOLDOWN   # a pair already touching presses, it does not bump again (the gloves sway on and off the chest: every re-touch looked fresh -> a 1 Hz bounce); a missed punch carrying the driver in still bumps
	var wa_eff: float = 0.0 if pa.bump_t > 0.0 else wa
	var wb_eff: float = 0.0 if pb.bump_t > 0.0 else wb
	if pa.bump_t > 0.0:
		pa.drive = 0.0
	if pb.bump_t > 0.0:
		pb.drive = 0.0
	if pa.stumble_t > 0.0:
		pa.drive = maxf(pa.drive, 0.8)
	if pb.stumble_t > 0.0:
		pb.drive = maxf(pb.drive, 0.8)
	var pressing_a: bool = pa.drive > 0.05
	var pressing_b: bool = pb.drive > 0.05
	var vc := 0.0
	if not both_up:
		pair.lock_t = 0.0
		pair.break_t = 0.0
	# ---- referee break: walk both apart, smooth
	if pair.break_t > 0.0:
		pair.break_el += dt
		pair.break_t -= dt
		var ramp := smoothstep(0.0, 0.25, pair.break_el)
		if gap >= BREAK_GAP:
			pair.break_t = 0.0
		else:
			var sp := BREAK_SPEED * ramp
			pa.correction = u * (-sp - wa)
			pb.correction = u * (sp + wb)
			pa.last_vc = -sp
			pb.last_vc = -sp
		_set_pose_weights(pa, pb, 0.0, 0.0, active, dt)
		return
	# ---- force balance (only while neither fighter is backing out of it)
	var retreat: bool = wa < -0.15 or wb < -0.15
	var bumping: bool = pa.bump_t > 0.0 or pb.bump_t > 0.0
	if active and (pressing_a or pressing_b or bumping) and not retreat:
		var ma: float = strength(a)
		var mb: float = strength(b)
		var plant_a: float = 0.0 if pressing_a else ma * PLANT
		var plant_b: float = 0.0 if pressing_b else mb * PLANT
		vc = (ma * maxf(wa_eff, 0.0) - mb * maxf(wb_eff, 0.0)) / (ma + mb + plant_a + plant_b)
		var floor_gap: float = CONTACT_FLOOR + 0.005 + FRAME_EXTRA * maxf(pa.frame_w, pb.frame_w)   # the bodies meet at the real spacing (a frame holds a hand more)
		var close := clampf((gap - floor_gap) * 6.0, 0.0, 0.5)
		var opn := clampf((floor_gap - gap) * 8.0, 0.0, 0.6)
		pa.correction = u * (vc - wa + 0.5 * close - opn)
		pb.correction = u * (vc + wb - 0.5 * close + opn)
		pa.last_vc = vc
		pb.last_vc = vc
	# ---- chest to chest the pair cannot orbit each other at full speed: the relative sideways velocity is damped
	if active and (pa.drive > 0.05 or pb.drive > 0.05) and a.state == a.State.IDLE and b.state == b.State.IDLE and not (a.slip_dir != 0 or b.slip_dir != 0):
		var tv := Vector3(-u.z, 0.0, u.x)
		var tw: float = clampf((TURN_RANGE - gap) / 0.25, 0.0, 1.0)
		var rel: float = (_flat(b.velocity).dot(tv) - _flat(a.velocity).dot(tv)) * 0.5
		pa.correction += tv * (rel * TURN_DAMP * tw)
		pb.correction -= tv * (rel * TURN_DAMP * tw)
	# ---- ropes: who is wedged between the foe and the wall
	if active:
		for x in [[a, pa, -u], [b, pb, u]]:
			var pos: Vector3 = x[0].global_position
			var n := Vector3(signf(pos.x), 0, 0) if absf(pos.x) >= absf(pos.z) else Vector3(0, 0, signf(pos.z))
			var edge := maxf(absf(pos.x), absf(pos.z))
			x[1].pinned = edge > WALL - 0.18 and (x[2] as Vector3).dot(n) > 0.3
	# ---- lean weights for the pose (and the stamina bill)
	var back_a := clampf(-vc / 0.5, 0.0, 1.0) if (pressing_b and not pressing_a or vc < 0.0) else 0.0
	var back_b := clampf(vc / 0.5, 0.0, 1.0) if (pressing_a and not pressing_b or vc > 0.0) else 0.0
	if pa.pinned and pressing_b:
		back_a = maxf(back_a, 0.7)
	if pb.pinned and pressing_a:
		back_b = maxf(back_b, 0.7)
	_set_pose_weights(pa, pb, back_a, back_b, active, dt)
	_stamina(pa, a, pb, b, dt, back_a, back_b)
	# ---- referee break counter: both leaning (or one pinned and leaned on), nobody punching
	var punching: bool = a.state == a.State.ATTACK or b.state == b.State.ATTACK
	var locked: bool = active and not punching and ((pressing_a and pressing_b and pa.drive > 0.3 and pb.drive > 0.3) \
			or (pa.pinned and pressing_b) or (pb.pinned and pressing_a))
	if locked and pair.break_cd <= 0.0:
		pair.lock_t += dt * (1.0 if (pa.drive > 0.3 and pb.drive > 0.3) else 0.5)
		if pair.lock_t >= BREAK_AFTER:
			pair.lock_t = 0.0
			pair.break_t = BREAK_MAX
			pair.break_el = 0.0
			pair.break_cd = 5.0
			pa.breaks += 1
			pb.breaks += 1
			pa.referee_break.emit()
			pb.referee_break.emit()   # Match listens to fighter 0 only
	elif punching or not active:
		pair.lock_t = maxf(pair.lock_t - dt * 3.0, 0.0)
	else:
		pair.lock_t = maxf(pair.lock_t - dt * 0.5, 0.0)


## Fresh contact at speed. 1-D collision along the line of centres by mass (restitution RESTITUTION): the driver is stopped
## and stumbles (no punch for ~0.2 s, off balance, entry step cancelled), the other is bumped back and his guard jolts.
## A driver who was mid-punch and had missed is overextended: he is not stopped, he stumbles on into the foe
## (chest to chest, head on his shoulder) and the pair is inside.
func _do_bump(a: Node3D, b: Node3D, pa: Object, pb: Object, u: Vector3, ca: float, cb: float, over_a: bool, over_b: bool) -> void:
	pair.bump_cd = BUMP_COOLDOWN
	var ma: float = mass_of(a)
	var mb: float = mass_of(b)
	var xa: float = maxf(ca, 0.0)
	var xb: float = -maxf(cb, 0.0)
	var vr: float = xa - xb
	var sev: float = clampf((vr - 0.4) / 2.2, 0.2, 1.0)
	var dxa: float = ((ma - RESTITUTION * mb) * xa + (1.0 + RESTITUTION) * mb * xb) / (ma + mb) - xa
	var dxb: float = ((mb - RESTITUTION * ma) * xb + (1.0 + RESTITUTION) * ma * xa) / (ma + mb) - xb
	var drv_a: bool = ca >= cb
	# how far each is moved by the exchange (m), _push decays with exp(-10 t) so displacement = v0 / 10
	var back_a: float = clampf(-dxa * 0.10, 0.0, 0.25)
	var back_b: float = clampf(dxb * 0.10, 0.0, 0.25)
	var pushed: Object = pb if drv_a else pa
	var driver: Object = pa if drv_a else pb
	var d_fighter: Node3D = a if drv_a else b
	var p_fighter: Node3D = b if drv_a else a
	var over: bool = over_a if drv_a else over_b
	var back_drv: float = back_a if drv_a else back_b
	var back_psh: float = back_b if drv_a else back_a
	var psh_dir: Vector3 = u if drv_a else -u        # world direction the pushed fighter moves
	back_psh = maxf(back_psh, 0.05 + 0.07 * sev)     # at least a visible step back
	p_fighter._push += psh_dir * back_psh * 10.0
	pushed.stagger_t = maxf(pushed.stagger_t, 0.15 + 0.2 * sev)
	pushed.bump_hit_t = 0.3
	p_fighter.stats.guard_lock = maxf(p_fighter.stats.guard_lock, 0.12 + 0.25 * sev)   # guard jolt
	pushed.kick = -0.4 - 0.5 * sev
	driver.bumps += 1
	driver.no_punch_t = maxf(driver.no_punch_t, STUMBLE_NO_PUNCH + 0.1 * sev)
	driver.stagger_t = maxf(driver.stagger_t, 0.3 + 0.25 * sev)
	if over:
		# overextended: he falls on into the foe, chest to chest, head on his shoulder
		driver.stumble_t = 0.55
		driver.kick = 1.0
		pair.side = 1.0 if drv_a else -1.0
		pair.adv = clampf(pair.adv + (-0.6 if drv_a else 0.6), -1.0, 1.0)   # the foe now holds the inside
	else:
		driver.bump_t = BUMP_TIME
		driver.kick = -0.5 - 0.3 * sev
		d_fighter._push -= psh_dir * (0.02 + 0.4 * back_drv) * 10.0   # small recoil off the foe
	d_fighter._lunge_left = 0.0   # the entry step ends at the foe


## Head-position battle (chest contact): who holds the inside. Strength, drive, the CPU's head fighting and a slow swing.
func _head_battle(pa: Object, pb: Object, a: Node3D, b: Node3D, active: bool, dt: float) -> void:
	if not active:
		pair.adv = lerpf(pair.adv, 0.0, 1.0 - exp(-1.5 * dt))
		pa.inside_pos = pair.adv
		pb.inside_pos = -pair.adv
		return
	if pair.contact_t <= dt * 1.5:
		pair.phase = float(Engine.get_physics_frames() % 997) * 0.37
	var sa: float = strength(a)
	var sb: float = strength(b)
	var t: float = pair.contact_t
	var swing: float = 0.45 * sin(t * 1.7 + pair.phase) + 0.25 * sin(t * 0.61 + 2.0 * pair.phase)
	var tgt: float = 1.6 * (sa - sb) / (sa + sb) + 0.5 * (pa.head_push - pb.head_push) + 0.3 * (pa.drive - pb.drive) + swing
	tgt += 0.25 * (pb.frame_w - pa.frame_w)   # a frame blunts the other's head work a little
	pair.adv = lerpf(pair.adv, clampf(tgt, -1.0, 1.0), 1.0 - exp(-3.0 * dt))
	pa.inside_pos = pair.adv
	pb.inside_pos = -pair.adv


func _set_pose_weights(pa: Object, pb: Object, back_a: float, back_b: float, active: bool, dt: float) -> void:
	var k := 1.0 - exp(-9.0 * dt)
	for x in [[pa, back_a], [pb, back_b]]:
		var p: Object = x[0]
		var cw: float = 1.0 if active else 0.0
		p.contact_w = lerpf(p.contact_w, cw, k)
		p.press_w = lerpf(p.press_w, p.drive * cw, k)
		p.pressed_w = lerpf(p.pressed_w, float(x[1]) * cw, k)


## Leaning drains: the pusher a little, the pressed fighter more (tired and pinned men most).
func _stamina(pa: Object, a: Node3D, pb: Object, b: Node3D, dt: float, back_a: float, back_b: float) -> void:
	for x in [[pa, a, back_a], [pb, b, back_b]]:
		var p: Object = x[0]
		var fi: Node3D = x[1]
		var st: Object = fi.stats
		if st.infinite_stamina:
			continue
		# halved after the owner asked for more stamina: chest-to-chest work was emptying CPUs in round 1
		var cost: float = 1.0 * p.drive + 1.2 * float(x[2]) * (1.5 if p.pinned else 1.0) * (1.0 + 1.5 * st.fatigue())
		if cost > 0.0:
			st.stamina = maxf(st.stamina - cost * dt, 0.0)
			if p.pinned or float(x[2]) > 0.2 or cost > 1.6:   # being leaned on / pinned stops the recovery; the presser leaning lightly can breathe
				st.stamina_lock = maxf(st.stamina_lock, 0.25)


func _after_resolve(_dt: float) -> void:
	pass


## A lead-forearm frame: in chest contact a fighter who guards (blocking input, or the CPU asking) and is not leaning on
## the foe puts his lead forearm on the foe's chest / shoulder to hold the space.
func _update_frame(dt: float) -> void:
	var want := false
	if in_contact and f.state == f.State.IDLE and stagger_t <= 0.0 and shove_t <= 0.0 and bump_t <= 0.0 and drive < 0.5 \
			and f.foe != null and f.foe.state != f.State.ATTACK:   # a punch coming in: both hands go back to guarding
		want = frame_hold > 0.0 or (f.inp != null and f.inp.block and f.foe.bc.drive > 0.3)   # a guarding fighter frames once the foe leans on him
	frame_w = lerpf(frame_w, 1.0 if want else 0.0, 1.0 - exp(-9.0 * dt))
	if want and not f.stats.infinite_stamina:
		f.stats.stamina = maxf(f.stats.stamina - FRAME_COST * dt, 0.0)
		f.stats.stamina_lock = maxf(f.stats.stamina_lock, 0.25)


func is_framing() -> bool:
	return frame_w > 0.5


## smother_factor() plus the head-position battle: whoever holds the inside lands short punches a little better.
func smother_for(s: Dictionary) -> float:
	var gap: float = f.gap_to_foe()
	var k := smother_factor(s, gap, contact_t)
	if contact_t > 0.3 and _type_factor(s) >= 0.85 and not (bool(s.get("is_leg", false))):
		k *= 1.0 + 0.12 * inside_pos
	return k


# ------------------------------------------------------------------ shove-off
func can_shove() -> bool:
	var foe: Node3D = f.foe
	if foe == null or foe.bc == null or shove_cd > 0.0 or shove_t > 0.0 or stagger_t > 0.0:
		return false
	if not (f.state in [f.State.IDLE, f.State.SLIP]) or f.frozen:
		return false
	if not _standing(f) or not _standing(foe) or pair == null or pair.tgap > SHOVE_TORSO_GAP:
		return false
	if pair != null and pair.break_t > 0.0:
		return false
	return f.stats.infinite_stamina or f.stats.stamina >= 12.0


func try_shove() -> bool:
	if not can_shove():
		return false
	var foe: Node3D = f.foe
	var u: Vector3 = _flat(foe.global_position - f.global_position).normalized()
	var sep := shove_distance(f, foe, foe.bc.drive)
	# how much of the space the shoved fighter can really give before the ropes (the rest is the shover's recoil + a rebound)
	var pos: Vector3 = foe.global_position
	var n := Vector3(signf(pos.x), 0, 0) if absf(pos.x) >= absf(pos.z) else Vector3(0, 0, signf(pos.z))
	var room := 9.0
	if u.dot(n) > 0.2:
		room = maxf((WALL - maxf(absf(pos.x), absf(pos.z))) / maxf(u.dot(n), 0.2), 0.0)
	var give := minf(0.8 * sep, room)
	foe._push += u * give * 10.0           # _push decays with exp(-10 t): the displacement is v0 / 10
	f._push -= u * (sep - give) * 10.0
	var wall_hit := room < 0.8 * sep
	foe.bc.stagger_t = SHOVED_OFF_BALANCE + (0.15 if wall_hit else 0.0)
	foe.bc.no_punch_t = SHOVED_NO_PUNCH
	foe.stats.guard_lock = maxf(foe.stats.guard_lock, 0.3)
	foe.bc.kick = -1.0
	if wall_hit:
		foe.bc._rebound_dir = -u
		foe.bc._rebound = 0.10 + 0.06 * (1.0 - room / maxf(0.8 * sep, 0.01))
		foe.bc._rebound_t = 0.14
	shove_t = SHOVE_LOCK
	no_punch_t = maxf(no_punch_t, 0.1)
	shove_cd = SHOVE_COOLDOWN
	kick = 0.6
	shoves_thrown += 1
	if not f.stats.infinite_stamina:
		f.stats.spend_stamina(SHOVE_COST, 0.5)
	pair.lock_t = 0.0
	return true


## Ropes give a little: a delayed push back off the wall.
func _tick_rebound(dt: float) -> void:
	if _rebound_t <= 0.0:
		return
	_rebound_t -= dt
	if _rebound_t <= 0.0 and f != null:
		f._push += _rebound_dir * _rebound * 10.0
		_rebound = 0.0
