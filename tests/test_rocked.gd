extends SceneTree
const HurtState := preload("res://scripts/combat/hurt_state.gd")
# Rocked / hurt rework: head daze, body fold, CPU pressing a hurt foe, hurt CPU covering up.
# godot --headless --path . --script res://tests/test_rocked.gd [--fixed-fps 120]
# Prints PASS/FAIL and exits 0 / 1.

const DT := 1.0 / 120.0
var failures := 0
var m: Match
var hits: Array = []
var whiffs: Array = []
var states: Array = []


func check(ok: bool, msg: String) -> void:
	if ok:
		print("  ok   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1


func steps(n: int) -> void:
	for i in n:
		await physics_frame


func make_match(cfg: Dictionary) -> void:
	if m != null:
		get_root().remove_child(m)
		m.queue_free()
		await process_frame
	hits.clear()
	whiffs.clear()
	states.clear()
	m = load("res://scenes/match.tscn").instantiate()
	var full := {"intro_delay": 0.0}
	full.merge(cfg, true)
	m.setup(full)
	m.hit_landed.connect(func(i, info): hits.append({"i": i, "info": info}))
	m.whiffed.connect(func(i, s): whiffs.append({"i": i, "strike": s}))
	m.fighter_state_changed.connect(func(i, s): states.append([i, s]))
	get_root().add_child(m)
	await process_frame


## two scripted dummies facing each other `gap` metres apart (centre to centre). The scripted hooks are unaimed and end at chin height: with contact-only hits they land from ~0.6 m, not 0.9 m
func duel(gap: float) -> Array:
	await make_match({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy", "rounds": 1, "round_seconds": 120.0})
	var f: Array = m.get_fighters()
	f[0].global_position = Vector3(-gap * 0.5, 0, 0)
	f[1].global_position = Vector3(gap * 0.5, 0, 0)
	f[0].external_input = FighterInput.new()
	f[1].external_input = FighterInput.new()
	watch(f[0])
	watch(f[1])
	await steps(90)
	return f


func throw(fighter: Fighter, tag: String) -> void:
	fighter.external_input.strikes.append(tag)
	await steps(1)
	fighter.external_input.strikes.clear()


const WATCH := ["hip", "head", "chestUpper", "lHand", "rHand"]
var _pose := {}   ## fighter instance id -> {bone: world position} captured when the skeleton finished its modifiers


## Skeleton poses are only final inside Skeleton3D.skeleton_updated (after the modifiers); outside it the bones
## show the raw animation again. So the bones are sampled from that signal.
func watch(f: Fighter) -> void:
	var sk: Skeleton3D = f.rig.skeleton
	sk.skeleton_updated.connect(func():
		if not sk.is_inside_tree():
			return
		var d := {}
		for b in WATCH:
			d[b] = sk.global_transform * sk.get_bone_global_pose(sk.find_bone(b)).origin
		_pose[f.get_instance_id()] = d)


func bone_pos(f: Fighter, bone: String) -> Vector3:
	return _pose[f.get_instance_id()][bone]


## height of the gloves above the hip bone (average of both hands)
func hands_above_hip(f: Fighter) -> float:
	var h := bone_pos(f, "hip").y
	return ((bone_pos(f, "lHand").y - h) + (bone_pos(f, "rHand").y - h)) * 0.5


## chest forward pitch in radians (hip -> chestUpper, in the fighter's frame; + = leaning forward)
func chest_pitch(f: Fighter) -> float:
	var v := f.global_basis.inverse() * (bone_pos(f, "chestUpper") - bone_pos(f, "hip"))
	return atan2(v.z, v.y)


## head height above the floor
func head_y(f: Fighter) -> float:
	return bone_pos(f, "head").y


## Spam LJab on `f` every tick until it starts attacking (or `limit` steps). Returns seconds waited, or -1.
func time_to_first_strike(f: Fighter, limit: int) -> float:
	var n := 0
	while n < limit:
		f.external_input.strikes.append("LJab")
		await steps(1)
		f.external_input.strikes.clear()
		n += 1
		if f.state == Fighter.State.ATTACK:
			return float(n) * DT
	return -1.0


## Walk speed of `f` (world z, 0.4 s settle + 0.3 s measure).
func walk_speed(f: Fighter) -> float:
	f.external_input.move = Vector2(0, 1)
	await steps(48)
	var p0 := f.global_position
	await steps(36)
	var p1 := f.global_position
	f.external_input.move = Vector2.ZERO
	return p0.distance_to(p1) / (36.0 * DT)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var dt: float = DT

	print("== A. power head shot -> rocked daze")
	var f := await duel(0.60)
	var t: Fighter = f[1]
	var a: Fighter = f[0]
	var base_hands := hands_above_hip(t)
	var base_speed := await walk_speed(t)
	t.global_position = Vector3(0.30, 0, 0)
	await steps(30)
	check(not t.stats.rocked and not t.hurt.active(), "healthy before the hit")
	t.stats.rock_meter = 40.0          # makes the next head shot meet the rock threshold
	await throw(a, "RHook")
	await steps(40)
	var rocked_hit: bool = hits.size() >= 1 and hits[0]["info"]["rocked"]
	check(rocked_hit and t.stats.rocked and t.hurt.is_head(), "RHook with rock meter 40 rocks (hits=%d)" % hits.size())
	check(states.has([1, "rocked"]), "fighter_state_changed emitted 'rocked' for the target: %s" % str(states.filter(func(s): return s[0] == 1)))
	var daze := t.hurt.daze_len
	check(daze >= 1.40 and daze <= 1.80, "daze length %.2f s within 1.4-1.8" % daze)
	check(t.stats.stun_left > daze + 1.0, "rocked flag outlasts the daze (stun_left %.2f)" % t.stats.stun_left)
	check(t.hurt.dazed() and t.rock_lock > 0.0, "dazed with offence lock %.2f s" % t.rock_lock)
	# let the flinch end and the pose layer settle (about 0.9 s after the hit)
	await steps(48)
	var daze_hands := hands_above_hip(t)
	check(daze_hands < 0.30 and daze_hands < base_hands - 0.25,
		"gloves at the belt during the daze: %.2f m above the hip (idle %.2f)" % [daze_hands, base_hands])
	check(bone_pos(t, "lHand").y < bone_pos(t, "head").y - 0.35 and bone_pos(t, "rHand").y < bone_pos(t, "head").y - 0.35, "both gloves well below the chin")
	var daze_speed := await walk_speed(t)
	var ratio := daze_speed / base_speed
	check(ratio > 0.42 and ratio < 0.62, "dazed move speed %.2f vs %.2f m/s healthy = x%.2f (about half)" % [daze_speed, base_speed, ratio])
	check(t.state != Fighter.State.ATTACK and whiffs.is_empty(), "no strike while dazed (state %s)" % t.state_name)

	print("== A2. no strike can start during the daze, then the guard returns")
	f = await duel(0.60)
	t = f[1]
	a = f[0]
	base_hands = hands_above_hip(t)
	t.stats.rock_meter = 40.0
	await throw(a, "RHook")
	var n_wait := 0
	while not t.hurt.is_head() and n_wait < 120:
		await steps(1)
		n_wait += 1
	check(t.hurt.is_head(), "rocked after the hook")
	var t_start := t.hurt.t
	daze = t.hurt.daze_len
	# spam strikes (and a strike every tick) for the whole daze and past it
	var first_attack := -1.0
	var attacked_in_daze := false
	var steps_n := 0
	while steps_n < int(3.0 / dt):
		t.external_input.strikes.append("RJab")
		await steps(1)
		t.external_input.strikes.clear()
		steps_n += 1
		var el := t.hurt.t if t.hurt.active() else daze + 1.0
		if t.state == Fighter.State.ATTACK:
			if el < daze - 0.03:
				attacked_in_daze = true
			if first_attack < 0.0:
				first_attack = el
				break
	check(not attacked_in_daze, "spamming strikes: no attack started before the daze ended (%.2f s)" % daze)
	check(first_attack >= daze - 0.03 and first_attack <= daze + 0.2, "first strike %.2f s after the hit, daze %.2f s" % [first_attack, daze])
	# guard back over ~0.35 s: new episode, measure hands at daze + 0.6 s
	f = await duel(0.60)
	t = f[1]
	a = f[0]
	base_hands = hands_above_hip(t)
	t.stats.rock_meter = 40.0
	await throw(a, "RHook")
	while not t.hurt.is_head():
		await steps(1)
	daze = t.hurt.daze_len
	while t.hurt.t < daze - 0.1:
		await steps(1)
	var late_hands := hands_above_hip(t)
	check(late_hands < 0.30, "gloves still down just before the daze ends (%.2f)" % late_hands)
	while t.hurt.t < daze + HurtState.GUARD_RETURN + 0.15:
		await steps(1)
	var back_hands := hands_above_hip(t)
	check(back_hands > base_hands - 0.12, "guard restored after the daze: gloves %.2f m above hip (idle %.2f)" % [back_hands, base_hands])
	check(t.hurt.block_weakness() == 1.0 and t.stats.rocked, "block weakness gone after the daze, still rocked (tail)")

	print("== A3. random look per episode")
	var looks := {}
	for i in 6:
		var h := HurtState.new()
		h.start_head(0.7, t.rng)
		looks[snappedf(h.sway_sign * h.sway_amp, 0.001)] = true
	check(looks.size() >= 5, "sway parameters differ between episodes (%d distinct of 6)" % looks.size())
	var h1 := HurtState.new()
	h1.start_head(0.35, t.rng)
	var h2 := HurtState.new()
	h2.start_head(1.0, t.rng)
	check(absf(h1.daze_len - 1.41) < 0.01 and absf(h2.daze_len - 1.8) < 0.01, "daze scales with severity: %.2f .. %.2f" % [h1.daze_len, h2.daze_len])

	print("== B. body shot -> short waist fold")
	f = await duel(0.60)
	t = f[1]
	a = f[0]
	var base_pitch := chest_pitch(t)
	var base_head := head_y(t)
	t.stats.body = 30.0                 # weakened body: the next clean body shot folds him
	await throw(a, "RBodyHook")
	var peak_pitch := base_pitch
	var min_head := base_head
	var body_seen := false
	for i in int(1.6 / dt):
		await steps(1)
		peak_pitch = maxf(peak_pitch, chest_pitch(t))
		min_head = minf(min_head, head_y(t))
		body_seen = body_seen or t.hurt.is_body()
	check(body_seen and states.has([1, "hurt_body"]), "body shot enters hurt_body (states %s)" % str(states.filter(func(s): return s[0] == 1)))
	check(not t.stats.rocked, "a body fold is not the head 'rocked' state")
	check(peak_pitch - base_pitch > 0.45, "torso folds forward: chest pitch %.0f deg -> %.0f deg" % [rad_to_deg(base_pitch), rad_to_deg(peak_pitch)])
	check(base_head - min_head > 0.12, "knee dip lowers the head %.2f m" % (base_head - min_head))
	# duration: second dummy, spam strikes
	f = await duel(0.60)
	t = f[1]
	a = f[0]
	t.stats.body = 30.0
	await throw(a, "RBodyHook")
	while not t.hurt.is_body():
		await steps(1)
	var body_len := t.hurt.body_len
	var t_body := await time_to_first_strike(t, 300)
	check(body_len >= 0.8 and body_len <= 1.2, "body hurt length %.2f s (0.8-1.2)" % body_len)
	check(t_body > 0.0 and t_body < daze - 0.2, "body fold unlocks offence after %.2f s, shorter than the %.2f s head daze" % [t_body, daze])
	check(t.hurt.cooldown > 0.0 or not t.hurt.active(), "body fold has a cooldown (%.1f s)" % t.hurt.cooldown)

	print("== C. CPU presses a hurt opponent")
	var res := {}
	for hurt_it in [false, true]:
		await make_match({"mode": "exhibition", "p1_controller": "cpu", "p2_controller": "dummy", "rounds": 1, "round_seconds": 120.0, "cpu_difficulty": "normal"})
		var g: Array = m.get_fighters()
		g[0].global_position = Vector3(-0.85, 0, 0)
		g[1].global_position = Vector3(0.85, 0, 0)
		g[1].external_input = FighterInput.new()
		await steps(30)
		var c: Fighter = g[0]
		var d: Fighter = g[1]
		if hurt_it:
			d.hurt.start_head(0.8, d.rng)
			d.stats.rocked = true
			d.stats.stun_left = d.hurt.total_len()
			d.rock_lock = d.hurt.daze_len
		var serial0: int = c._serial
		var min_gap := 9.0
		for i in int(2.4 / dt):
			await steps(1)
			min_gap = minf(min_gap, c.gap_to_foe())
		res[hurt_it] = {"strikes": c._serial - serial0, "hits": hits.filter(func(h): return h["i"] == 0).size(), "gap": min_gap}
	print("  info healthy foe %s | hurt foe %s" % [str(res[false]), str(res[true])])
	check(res[true]["strikes"] >= res[false]["strikes"] and res[true]["strikes"] >= 3, "CPU strike rate vs hurt foe %d >= healthy foe %d (and >= 3)" % [res[true]["strikes"], res[false]["strikes"]])
	check(res[true]["gap"] <= res[false]["gap"] + 0.01 and res[true]["gap"] < 0.95, "CPU closes to %.2f m on a hurt foe (healthy foe: %.2f m)" % [res[true]["gap"], res[false]["gap"]])

	print("== D. hurt CPU covers up and backs off")
	await make_match({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "cpu", "rounds": 1, "round_seconds": 120.0, "cpu_difficulty": "hard"})
	var g2: Array = m.get_fighters()
	g2[0].global_position = Vector3(-0.45, 0, 0)
	g2[1].global_position = Vector3(0.45, 0, 0)
	g2[0].external_input = FighterInput.new()
	await steps(30)
	var cpu: Fighter = g2[1]
	cpu.hurt.start_head(0.8, cpu.rng)
	cpu.stats.rocked = true
	cpu.stats.stun_left = cpu.hurt.total_len()
	cpu.rock_lock = cpu.hurt.daze_len
	var gap0 := cpu.gap_to_foe()
	var blocked_ticks := 0
	var attacked := false
	var prev_state: int = cpu.state
	for i in int(1.2 / dt):
		await steps(1)
		blocked_ticks += 1 if cpu.inp.block else 0
		# count only strikes STARTED while hurt (the forced daze can land mid-strike, with no hit to interrupt it)
		attacked = attacked or (cpu.state == Fighter.State.ATTACK and prev_state != Fighter.State.ATTACK)
		prev_state = cpu.state
	check(cpu.gap_to_foe() > gap0 + 0.25 and blocked_ticks > 100 and not attacked,
		"hurt CPU backs off (%.2f -> %.2f m), holds block %d ticks, no strike" % [gap0, cpu.gap_to_foe(), blocked_ticks])

	print("== E. knockdown clears the hurt state")
	f = await duel(0.60)
	t = f[1]
	t.hurt.start_head(0.8, t.rng)
	t.stats.rocked = true
	t._do_knockdown("F")
	check(not t.hurt.active() and t.rock_lock == 0.0, "knockdown clears hurt state and offence lock")

	if failures == 0:
		print("PASS: rocked / hurt rework")
		quit(0)
	else:
		print("FAIL: %d check(s) failed" % failures)
		quit(1)
