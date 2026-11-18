class_name CpuBrain
extends RefCounted
## CPU opponent (spec section 8). Produces a FighterInput each physics tick. Difficulty = reaction delay,
## return-jab chance, defensive alertness, slip share, cadence and aggression.

const PROFILES := {
	# `react` = seconds from the foe's strike STARTING to the CPU choosing a defence. Strike contact now comes
	# 0.26-0.5 s after the start (StrikeDB time remap), so easy (0.32+) is too late for nearly everything,
	# normal (0.17-0.27) catches the odd jab / most hooks, hard (0.10-0.17) defends a good share of jabs.
	"easy": {"react": Vector2(0.32, 0.48), "meet": 0.12, "alert": 0.12, "slip": 0.10, "cadence": 1.45, "aggr": 0.55, "counter": 0.25, "combo": 0.35, "rest": 2.2, "feet": 0.5, "parry": 0.0},
	"normal": {"react": Vector2(0.17, 0.27), "meet": 0.40, "alert": 0.35, "slip": 0.25, "cadence": 1.0, "aggr": 1.0, "counter": 0.55, "combo": 0.6, "rest": 1.3, "feet": 0.8, "parry": 0.08},
	"hard": {"react": Vector2(0.10, 0.17), "meet": 0.45, "alert": 0.55, "slip": 0.35, "cadence": 0.78, "aggr": 1.3, "counter": 0.85, "combo": 0.8, "rest": 1.0, "feet": 1.0, "parry": 0.18},
}
const CpuDefenceScript := preload("res://scripts/ai/cpu_defence.gd")
const CpuStaminaScript := preload("res://scripts/ai/cpu_stamina.gd")   # fatigue pass: back off when gassed, press a gassed foe
const GuardModelScript := preload("res://scripts/combat/guard_model.gd")
const ExchangeScript := preload("res://scripts/combat/exchange.gd")
const CpuPunchScript := preload("res://scripts/ai/cpu_punch.gd")   # punch variant choice (flick / lunge / wide hook ...)
const CpuStyleScript := preload("res://scripts/ai/cpu_style.gd")   # polish pass: out-boxer / pressure per fighter
const CpuPaceScript := preload("res://scripts/ai/cpu_pace.gd")   # polish pass: bursts of 2-4 then reset, round-opening feeling-out
const CpuContactScript := preload("res://scripts/ai/cpu_contact.gd")   # body contact: lean on / shove off / short punches in close
const CpuFootworkScript := preload("res://scripts/ai/cpu_footwork.gd")   # polish pass: circling, in-and-out, cut-off, pivot, feints
const COMBOS := {
	"LJab": [["LJab", "LJab"], ["LJab", "LHook"], ["LJab", "LUppercut"], ["LJab", "RJab"], ["LJab", "RHook"], ["LJab", "RUppercut"],
		["LJab", "LJab", "RJab"], ["LJab", "LJab", "RHook"], ["LJab", "RJab", "LJab"], ["LJab", "RHook", "LHook"], ["LJab", "RBodyHook"],
		["LJab", "LJab", "RBodyJab"], ["LJab", "RFrontKick"], ["LJab", "RLowKick"], ["LJab", "LJab", "RLowKick"]],
	"RJab": [["RJab", "LJab"], ["RJab", "LHook"], ["RJab", "LJab", "RJab"], ["RJab", "LJab", "RUppercut"], ["RJab", "LJab", "RFrontKick"]],
	"LHook": [["LHook", "RHook"], ["LHook", "RUppercut"]],
	"RHook": [["RHook", "LHook"]],
	"LUppercut": [["LUppercut", "RUppercut"]],
	"RUppercut": [["RUppercut", "LUppercut"], ["RUppercut", "LHook"]],
	"LBodyJab": [["LBodyJab", "RBodyJab"], ["LBodyJab", "RBodyHook"], ["LBodyJab", "RBodyJab", "LBodyJab"]],
	"RBodyHook": [["RBodyHook", "LBodyHook"]],
}

## Hits are contact-only now (volumes hug the visible body, gloves are 5-7 cm): a fist reaches ~5 cm less far than it did against the old big
## hit volumes. Every range threshold of the brain (strike windows, spacing) was tuned for that, so it measures the gap this much longer.
## Straights then gained ~8 cm of reach (the trunk leans in, punch_pose.gd REACH_LEAN) and the fighters were standing chest to chest next to the
## reference: every threshold moves out by 8 cm (0.05 -> -0.03), so the CPUs fight from a jab's length.
const REACH_TRIM := -0.03

var f: Fighter
var rng := RandomNumberGenerator.new()
var boxing := false
var diff: Dictionary = PROFILES["normal"]

var _assess := 0.0
var _cd := 0.0
var _combo: Array = []
var _combo_i := 0
var _lat_sign := 1.0
var _lat_t := 0.0
var _def_t := 0.0
var _def_kind := ""
var _def_slip := 0
var _def_ttc := 0.085   ## parry: press block when the punch is this close to contact (s)
var _parry_down := false   ## parry: the press has been made
var _seen_serial := -1
var _react_t := -1.0
var _threat: Dictionary = {}
var _meet_t := -1.0
var _alert_t := 0.0
var _alert_cd := 0.0
var _counter_t := -1.0
var _retreat_t := 0.0
var _pocket_t := 0.0
var _foe_active_t := 0.0
var _decide_t := 0.0     ## offence is re-decided every 0.1-0.25 s, not every tick
var _kick_cd := 0.0
var style: Dictionary = {}    ## cpu_style.gd row (resolved from the fighter's model in setup)
var pace = CpuPaceScript.new()
var fw = CpuFootworkScript.new()
var contact = CpuContactScript.new()
var _recovering := false   ## fatigue pass: catching its breath (guard up, backed off) until stamina is back above CpuStamina.EXIT


func setup(fighter: Fighter, difficulty: String, seed_value: int) -> void:
	f = fighter
	rng.seed = seed_value
	set_difficulty(difficulty)
	_assess = rng.randf_range(0.15, 0.35)
	_lat_sign = 1.0 if rng.randf() < 0.5 else -1.0
	style = CpuStyleScript.of(String(fighter.template))


## Round start (called by Fighter.reset_for_round): back to the feeling-out period.
func on_round_start(full: bool) -> void:
	pace.on_round_start(self, full)


func set_difficulty(name: String) -> void:
	diff = PROFILES.get(name, PROFILES["normal"])


func think(dt: float, inp: FighterInput) -> void:
	inp.clear()
	var foe := f.foe
	if foe == null or f.frozen or f.is_acute_down() or f.is_out():
		return
	_cd = maxf(_cd - dt, 0.0)
	_decide_t = maxf(_decide_t - dt, 0.0)
	_kick_cd = maxf(_kick_cd - dt, 0.0)
	_assess = maxf(_assess - dt, 0.0)
	_def_t = maxf(_def_t - dt, 0.0)
	_alert_t = maxf(_alert_t - dt, 0.0)
	_alert_cd = maxf(_alert_cd - dt, 0.0)
	_retreat_t = maxf(_retreat_t - dt, 0.0)
	_lat_t -= dt
	if _lat_t <= 0.0:
		_lat_t = rng.randf_range(1.1, 2.5)
		_lat_sign = -_lat_sign
	var gap := f.gap_to_foe() + REACH_TRIM
	var to_foe := f.dir_to_foe()
	pace.update(self, dt)
	fw.note_motion(f, to_foe, dt)
	var stam := f.stats.stamina_ratio()
	var health := f.stats.head / 100.0

	# ---- rocked / body-hurt (rocked rework): cover up and back off along a slightly curved line
	if f.stats.rocked or f.hurt.active():
		inp.block = true
		inp.body = f.hurt.is_body()
		_move_world(inp, -to_foe * 0.9 + Vector3(-to_foe.z, 0, to_foe.x) * _lat_sign * 0.3)
		return
	_recovering = CpuStaminaScript.recovering(_recovering, stam)
	var foe_hurt := _foe_hurt() or CpuStaminaScript.foe_tired(foe, stam)   # a gassed foe is pressed like a rocked one
	var recover := _recovering
	if foe_hurt:
		pace.cancel_rest()   # a rocked / gassed foe is pressed, not rested against
	var reset := stam < 0.40 or health < 0.30

	# ---- observe the foe's attack, react after a delay
	_observe_foe(dt, gap)
	if _react_t >= 0.0:
		_react_t -= dt
		if _react_t <= 0.0:
			_react_t = -1.0
			_choose_defence(gap)
	if _def_t > 0.0:
		_apply_defence(inp)
	elif _alert_t > 0.0:
		inp.block = true
		inp.body = false

	# ---- whiff punish
	if _counter_t >= 0.0:
		_counter_t -= dt
		if _counter_t <= 0.0:
			_counter_t = -1.0
			if _can_start() and gap <= 1.02 and foe.state == Fighter.State.ATTACK and not foe.atk.is_empty() and _foe_open():
				var t := CpuDefenceScript.counter_tag(self, "RJab" if rng.randf() < 0.6 else ("LHook" if gap <= 0.98 else "RHook"))
				if foe.head_low_or_forward() and gap <= 0.92 and rng.randf() < 0.75:
					t = "RUppercut" if rng.randf() < 0.7 else "LUppercut"   # punish a low / overextended head with the uppercut
				inp.strikes.append(t)
				_cd = 0.16 + 0.3 * diff["cadence"]
				_combo.clear()
	if foe.state == Fighter.State.ATTACK and not foe.atk.is_empty() and _foe_open() and _counter_t < 0.0 \
			and rng.randf() < diff["counter"] * dt * (22.0 if foe.atk["outcome"] == "parried" else 10.0) and gap <= 1.05:
		_counter_t = rng.randf_range(0.04, 0.10)

	# ---- queued combo continuation
	if f.state == Fighter.State.ATTACK and not _combo.is_empty() and _combo_i < _combo.size():
		if f.buffer.is_empty() and not f.atk.is_empty() and f.atk["t"] >= 0.3 * f.atk["A"] and gap <= 1.15 and f.stats.stamina > 25.0:
			inp.strikes.append(CpuPunchScript.pick(self, _combo[_combo_i], gap, _foe_hurt(), true))
			_combo_i += 1
		if _combo_i >= _combo.size():
			_combo.clear()

	# ---- offence (a hurt foe is pressed: no thinking pause, shorter decision gaps, offence even when a bit tired)
	if _def_t <= 0.0 and _meet_t < 0.0 and (_assess <= 0.0 or foe_hurt) and f.state == Fighter.State.IDLE and _cd <= 0.0 and not CpuDefenceScript.avoids_trade(self) \
			and (foe_hurt or not pace.resting) and not recover and (not reset or (foe_hurt and stam > 0.30)) and f.stats.stamina > (25.0 if reset and not foe_hurt else 15.0) and _decide_t <= 0.0:
		_decide_t = rng.randf_range(0.08, 0.2) * (0.5 if foe_hurt else 1.0)
		_try_offence(inp, gap, foe_hurt)

	# ---- resting: a paw of the jab to find the range (more often while feeling out)
	if pace.resting and not foe_hurt and f.state == Fighter.State.IDLE and _cd <= 0.0 and _def_t <= 0.0 and _meet_t < 0.0 \
			and gap >= 0.95 and gap <= 1.25 and not recover and not reset and f.stats.stamina > 30.0 \
			and rng.randf() < float(style["paw"]) * (0.22 if pace.opening > 0.0 else 0.07) * dt:
		inp.strikes.append(CpuPunchScript.pick(self, "LJab", gap, false))
		_cd = rng.randf_range(0.5, 0.9)

	# ---- meet an ordinary jab with a stepping return jab
	if _meet_t >= 0.0:
		_meet_t -= dt
		if _meet_t <= 0.0:
			_meet_t = -1.0
			if _can_start() and gap >= 0.66 and gap <= 1.06 and f.state == Fighter.State.IDLE and not CpuDefenceScript.avoids_trade(self):
				inp.strikes.append(CpuPunchScript.pick(self, "LJab" if rng.randf() < 0.7 else "RJab", gap, false))
				_cd = 0.16 + 0.35 * diff["cadence"]
				_def_t = 0.0

	# ---- alertness: random guard / slip windows while an active foe is in range
	if foe.state == Fighter.State.ATTACK:
		_foe_active_t = 1.4
	_foe_active_t = maxf(_foe_active_t - dt, 0.0)
	if f.state == Fighter.State.IDLE and gap < 1.15 and _alert_cd <= 0.0 and _def_t <= 0.0 and _foe_active_t > 0.0:
		_alert_cd = rng.randf_range(0.5, 1.2)
		if rng.randf() < diff["alert"]:
			_alert_t = rng.randf_range(0.30, 0.65)
			if rng.randf() < diff["slip"] * 0.6 and f.stats.stamina > 20.0:
				_def_slip = 1 if rng.randf() < 0.5 else -1
				_def_kind = "slip"
				_def_t = rng.randf_range(0.18, 0.32)
				_alert_t = 0.0

	# ---- movement / spacing
	_spacing(inp, gap, to_foe, recover, reset, dt, foe_hurt)
	contact.tick(self, dt, inp, gap, to_foe)   # body contact: lean on / shove off


## The foe's punch missed, was parried or was a loaded shot into my gloves: his recovery is a window to punish.
func _foe_open() -> bool:
	var o: String = f.foe.atk["outcome"]
	return o == "missed" or o == "parried" or (o == "blocked" and f.foe.atk["s"]["heavy"])


## The opponent is rocked or folded (rocked rework): worth pressing.
func _foe_hurt() -> bool:
	var foe := f.foe
	return foe != null and (foe.stats.rocked or foe.hurt.active()) and not foe.is_acute_down() and not foe.is_out()


func _can_start() -> bool:
	# (a slip / roll with an open counter window may throw straight out of it)
	var ready := f.state == Fighter.State.IDLE or (f.counter_window > 0.0 and f.state in [Fighter.State.SLIP, Fighter.State.CROUCH])
	return ready and f.stats.stamina > 15.0 and f.rock_lock <= 0.0


func _move_world(inp: FighterInput, w: Vector3) -> void:
	inp.move = Vector2(w.x, -w.z).limit_length(1.0)


func _observe_foe(dt: float, gap: float) -> void:
	var foe := f.foe
	if foe.state != Fighter.State.ATTACK or foe.atk.is_empty():
		if _react_t < 0.0:
			_threat = {}
		return
	if foe.atk["serial"] != _seen_serial:
		_seen_serial = foe.atk["serial"]
		_threat = foe.atk
		var s: Dictionary = foe.atk["s"]
		# the delay is a read of the punch, not a stopwatch: it shrinks with the hand tempo (StrikeDB.HAND_TEMPO), so a faster
		# punch is defended as often as the slower one this was tuned against
		_react_t = (rng.randf_range(diff["react"].x, diff["react"].y) + 0.01 * rng.randf()) * float(s.get("tempo", 1.0))
		# ordinary jab: sometimes meet it with a return jab instead of covering
		if String(s["tag"]).contains("Jab") and s["zone"] == "head" and rng.randf() < diff["meet"] and gap >= 0.66 and gap <= 1.06 \
				and f.stats.stamina > 20.0 and f.state == Fighter.State.IDLE:
			_meet_t = rng.randf_range(0.02, 0.06) + _react_t * 0.5
			_react_t = -1.0
		elif CpuDefenceScript.wants_trade(self, s, gap):   # exchange: beat a hook to the punch with a straight
			_meet_t = rng.randf_range(0.0, 0.03)
			_react_t = -1.0


func skill_of_diff() -> float:
	return clampf(float(diff["parry"]) / 0.25, 0.0, 1.0)


func _choose_defence(gap: float) -> void:
	if _threat.is_empty() or f.state != Fighter.State.IDLE:
		return
	var s: Dictionary = _threat["s"]
	if _threat.get("hit_done", false) or gap > s["reach"] + 0.35:
		return
	var zone: String = s["zone"]
	var tag: String = s["tag"]
	_def_kind = "guard"
	_def_t = clampf(float(s["action"]) * 0.7 + 0.1, 0.18, 0.56)
	if zone == "body":
		_def_kind = "body"
	elif zone == "leg":
		_def_kind = "step"
		_def_t = 0.3
	else:
		CpuDefenceScript.pick_head(self, s, gap)   # defence family: shell / tilt / slip / sway / roll / duck / step (scripts/ai/cpu_defence.gd)
		if _def_kind == "guard" and GuardModelScript.parryable(s) and f.stats.stamina > 20.0 and rng.randf() < float(diff["parry"]):
			_def_kind = "parry"   # hold off the press until the punch is about to land (a flick block), jittered
			_def_ttc = clampf(rng.randfn(0.085, 0.035 + 0.03 * (1.0 - skill_of_diff())), 0.02, 0.17)
			_parry_down = false
			_def_t = clampf(float(s["action"]) * 0.7 + 0.1, 0.3, 0.56)


func _apply_defence(inp: FighterInput) -> void:
	if CpuDefenceScript.apply(self, _def_kind, inp):
		return
	match _def_kind:
		"guard":
			inp.block = true
		"parry":
			if not _parry_down and not _threat.is_empty() and not _threat.get("hit_done", false) \
					and ExchangeScript.time_to_contact(_threat) <= _def_ttc:
				_parry_down = true
			inp.block = _parry_down
		"body":
			inp.block = true
			inp.body = true
		"duck":
			inp.duck = true
		"slip":
			inp.slip = _def_slip
		"step":
			_move_world(inp, -f.dir_to_foe())


func _try_offence(inp: FighterInput, gap: float, foe_hurt := false) -> void:
	var tag := ""
	var short: String = contact.short_tag(self, gap, foe_hurt)   # body contact: uppercuts / body hooks in close
	if short != "" and not (boxing and StrikeDB.get_strike(short).get("is_leg", false)):
		short = CpuStaminaScript.tame(short, f.stats.stamina_ratio(), rng)
		inp.strikes.append(CpuPunchScript.pick(self, short, gap, false))
		_cd = _cadence(short)
		_combo.clear()
		_combo_i = 0
		return
	var n := rng.randf()
	if foe_hurt and gap >= 0.55 and gap < 1.02:
		# press a hurt foe with power: hooks / uppercuts / the rear hand, a jab now and then to stay in range
		var m := rng.randf()
		if gap >= 0.94:
			tag = "RJab" if m < 0.6 else "LJab"
		elif m < 0.30:
			tag = "RHook"
		elif m < 0.52:
			tag = "LHook"
		elif m < 0.68:
			tag = "RUppercut" if gap <= 0.88 else "RHook"
		elif m < 0.84:
			tag = "RJab"
		else:
			tag = "LJab"
	elif foe_hurt:
		return   # out of punching range: walk in (no kicks at long range while pressing)
	elif gap >= 0.55 and gap < 0.94:
		if n < 0.30:
			tag = "LJab"
		elif n < 0.55:
			tag = "RJab"
		elif n < 0.75:
			tag = "LHook"
		elif n < 0.85:
			tag = "RHook"
		elif n < 0.925:
			tag = "LUppercut" if gap <= 0.88 else "LHook"
		else:
			tag = "RBodyHook"
	elif gap < 1.02:
		var m := rng.randf()
		tag = "LJab" if m < 0.55 else ("RJab" if m < 0.85 else "LBodyJab")
	elif not boxing and gap >= 1.18 and gap <= 1.30 and f.stats.stamina_ratio() > 0.55 and _kick_cd <= 0.0 and n < 0.22:
		tag = "LBodyRoundKick" if rng.randf() < 0.5 else "LRoundKick"
		_kick_cd = rng.randf_range(3.0, 5.0)   # kicks are an occasional shot, not a way to stand at range
	else:
		return
	if boxing and StrikeDB.get_strike(tag).get("is_leg", false):
		tag = "RJab"
	tag = _open_level(tag)   # guard pass: attack the level the foe's guard is not covering
	tag = CpuStaminaScript.tame(tag, f.stats.stamina_ratio(), rng)   # fatigue pass: tired CPUs jab
	inp.strikes.append(CpuPunchScript.pick(self, tag, gap, foe_hurt))   # punch variety
	_cd = _cadence(tag) * (0.7 if foe_hurt else 1.0)
	_combo.clear()
	_combo_i = 0
	if COMBOS.has(tag) and rng.randf() < (1.0 if foe_hurt else diff["combo"] * diff["aggr"] * 0.6):
		var opts: Array = COMBOS[tag]
		var pick: Array = opts[rng.randi() % opts.size()]
		var ok := true
		if boxing:
			for t in pick:
				if StrikeDB.get_strike(t).get("is_leg", false):
					ok = false
		if ok:
			_combo = pick.duplicate()
			_combo_i = 1


## A high guard is open to the body, a body guard to the head (the foe switches level with the Body modifier).
func _open_level(tag: String) -> String:
	var foe := f.foe
	if foe == null or not foe.guard_on or tag.length() < 4 or tag.contains("Kick"):
		return tag
	var body := tag.contains("Body")
	if not foe.guard_body and not body and not tag.contains("Uppercut"):
		if rng.randf() < 0.22 + 0.25 * float(diff["aggr"]) / 1.3:
			return tag.substr(0, 1) + "Body" + tag.substr(1)
	elif foe.guard_body and body:
		if rng.randf() < 0.75:
			return tag.replace("Body", "")
	return tag


func _cadence(tag: String) -> float:
	var s := StrikeDB.get_strike(tag)
	var base := 0.48
	if s.get("is_leg", false):
		base = 0.96
	elif tag.contains("Uppercut"):
		base = 0.68
	elif tag.contains("Hook"):
		base = 0.62
	return (base + 0.28 * rng.randf()) * 1.08 * diff["cadence"] / maxf(diff["aggr"], 0.4)


func _spacing(inp: FighterInput, gap: float, to_foe: Vector3, recover: bool, reset: bool, dt: float, foe_hurt := false) -> void:
	if f.state not in [Fighter.State.IDLE, Fighter.State.SLIP, Fighter.State.CROUCH] and f.state != Fighter.State.ATTACK:
		return
	if inp.move != Vector2.ZERO:
		return   # defensive step already chosen
	if f.state == Fighter.State.ATTACK:
		return
	if not (recover or reset or foe_hurt):
		# polish pass: normal fighting uses the footwork plans (circle / in-and-out / cut-off / pivot / feint)
		if pace.just_rested:
			fw.post_burst = true
		_move_world(inp, fw.want(self, gap, to_foe, dt, pace.resting, pace.opening > 0.0))
		if fw.slip != 0 and f.stats.stamina > 20.0:
			inp.slip = fw.slip
		return
	var lateral := Vector3(-to_foe.z, 0, to_foe.x) * _lat_sign
	var want := Vector3.ZERO
	var target := 0.93
	if recover:
		target = 1.62
		inp.block = gap < 1.3 or _foe_active_t > 0.0   # fatigue pass: guard up only when the foe is close / throwing; hands down regens faster
	elif reset:
		target = 1.30
	if foe_hurt and not recover:
		target = 0.80   # step into the pocket on a hurt foe and stay there
		_pocket_t = 0.0
		_retreat_t = 0.0
	if gap > target + 0.06:
		want += to_foe * clampf((gap - target) * 1.4, 0.25 if not foe_hurt else 0.6, 0.56 + 0.3 * diff["aggr"] + (0.3 if foe_hurt else 0.0))
	elif gap < target - 0.14:
		want -= to_foe * 0.5
	if _pocket_t > 0.0:
		_pocket_t -= dt
	if gap < 0.96 and not foe_hurt:
		_pocket_t += dt * 2.0
		if _pocket_t > 1.0:
			_retreat_t = 0.22
			_pocket_t = -2.0
	if _retreat_t > 0.0:
		want = -to_foe * 0.6 + lateral * 0.5
	elif gap < 1.6 and not recover and not foe_hurt:
		want += lateral * 0.35
	# stay off the ropes: bias to the ring centre when close to a wall
	var p := f.global_position
	var edge := maxf(absf(p.x), absf(p.z))
	if edge > 2.1:
		want += Vector3(-p.x, 0, -p.z).normalized() * 0.5
	if want.dot(to_foe) < -0.2:
		want += lateral * 0.45   # backing off goes along an angle, not straight back
	_move_world(inp, want)
