extends SceneTree
# Fatigue pass: stamina is a real resource and tiredness shows (slower / weaker strikes, lower guard, no power shots,
# CPU backs off), rocked states happen regularly (clean counter hook, 3-minute hard bout).
# godot --headless --fixed-fps 120 --path . --script res://tests/test_fatigue.gd
# Prints PASS/FAIL and exits 0 / 1.

const DT := 1.0 / 120.0
var failures := 0
var m: Match
var hits: Array = []
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
	states.clear()
	m = load("res://scenes/match.tscn").instantiate()
	var full := {"intro_delay": 0.0}
	full.merge(cfg, true)
	m.setup(full)
	m.hit_landed.connect(func(i, info): hits.append({"i": i, "info": info}))
	m.fighter_state_changed.connect(func(i, s): states.append([i, s]))
	get_root().add_child(m)
	await process_frame


## NOTE: literal (unaimed) punches only touch a head from ~0.6 m now that hits are contact-only; the damage / rock checks use that range
func duel(gap: float, rules := "boxing") -> Array:
	await make_match({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy", "rounds": 1, "round_seconds": 600.0, "rules": rules})
	var f: Array = m.get_fighters()
	f[0].global_position = Vector3(-gap * 0.5, 0, 0)
	f[1].global_position = Vector3(gap * 0.5, 0, 0)
	f[0].external_input = FighterInput.new()
	f[1].external_input = FighterInput.new()
	watch(f[0])
	watch(f[1])
	await steps(90)
	return f


## Lowest stamina over the next n physics frames: what a strike cost before rest regen refills it (a quick jab is over long
## before the window ends, so the end value is just the cap again).
func low_point(fighter: Fighter, n: int) -> float:
	var lo := fighter.stats.stamina
	for i in n:
		await physics_frame
		lo = minf(lo, fighter.stats.stamina)
	return lo


func throw(fighter: Fighter, tag: String) -> void:
	fighter.external_input.strikes.append(tag)
	await steps(1)
	fighter.external_input.strikes.clear()


const WATCH := ["hip", "head", "chestUpper", "lHand", "rHand"]
var _pose := {}


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


func hands_above_hip(f: Fighter) -> float:
	var h := bone_pos(f, "hip").y
	return ((bone_pos(f, "lHand").y - h) + (bone_pos(f, "rHand").y - h)) * 0.5


## Seconds from the first tick of `tag` until the fighter leaves the ATTACK state.
func action_seconds(f: Fighter, tag: String) -> float:
	await throw(f, tag)
	var n := 1
	while f.state == Fighter.State.ATTACK and n < 400:
		await steps(1)
		n += 1
	return n * DT


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("== A. a thrower who never lets up is gassed within 30 s (and not instantly)")
	var f := await duel(0.90)
	var a: Fighter = f[0]
	var t: Fighter = f[1]
	t.practice = true
	t.stats.practice = true
	var tags := ["LJab", "RJab", "LHook", "RHook", "LJab", "RUppercut"]
	var n := 0
	var gassed_at := -1.0
	var elapsed := 0.0
	while elapsed < 40.0:
		if n % 36 == 0:   # a punch every 0.3 s (the buffer chains them as fast as the strike timing allows)
			a.external_input.strikes.append(tags[(n / 36) % tags.size()])
		await steps(1)
		a.external_input.strikes.clear()
		n += 1
		elapsed = n * DT
		a.external_input.move = Vector2(0, 1) if a.gap_to_foe() > 0.95 else Vector2.ZERO
		if gassed_at < 0.0 and a.stats.stamina_ratio() < 0.30:
			gassed_at = elapsed
	check(gassed_at > 5.0 and gassed_at < 30.0, "non-stop thrower under 30 %% stamina after %.1f s (want 5..30)" % gassed_at)

	print("== B. resting regenerates, moving / blocking / throwing regenerate less")
	var st_rest := FighterStats.new()
	st_rest.stamina = 40.0
	st_rest.tick(2.0, false, false)
	var st_move := FighterStats.new()
	st_move.stamina = 40.0
	st_move.moving = true
	st_move.tick(2.0, false, false)
	var st_guard := FighterStats.new()
	st_guard.stamina = 40.0
	st_guard.tick(2.0, true, false)
	var st_busy := FighterStats.new()
	st_busy.stamina = 40.0
	st_busy.busy = true
	st_busy.tick(2.0, false, false)
	check(st_rest.stamina > st_move.stamina + 6.0 and st_move.stamina > st_guard.stamina - 0.1 and st_guard.stamina > st_busy.stamina + 10.0,
		"regen over 2 s from 40: rest %.0f > move %.0f >= guard %.0f > throwing %.0f" % [st_rest.stamina, st_move.stamina, st_guard.stamina, st_busy.stamina])
	f = await duel(1.6)
	a = f[0]
	a.stats.stamina = 30.0
	await steps(240)
	check(a.stats.stamina > 30.0 + 40.0, "standing off for 2 s restores %.0f stamina" % (a.stats.stamina - 30.0))
	var jab := StrikeDB.get_strike("LJab")
	var hook := StrikeDB.get_strike("RHook")
	var c := preload("res://scripts/combat/fatigue.gd")
	check(c.whiff_cost(jab) > 0.4 * c.strike_cost(jab) and c.strike_cost(hook) > 2.0 * c.strike_cost(jab),
		"whiffs cost extra (+%.1f on %.1f), a hook costs %.1f vs jab %.1f" % [c.whiff_cost(jab), c.strike_cost(jab), c.strike_cost(hook), c.strike_cost(jab)])
	f = await duel(2.4)
	a = f[0]
	var s0 := a.stats.stamina
	await throw(a, "LJab")
	var whiff_paid := s0 - await low_point(a, 150)   # nothing in reach: whiff
	f = await duel(0.60)
	a = f[0]
	f[1].practice = true
	f[1].stats.practice = true
	s0 = a.stats.stamina
	await throw(a, "LJab")
	var hit_paid := s0 - await low_point(a, 150)   # lands
	check(whiff_paid > hit_paid + 1.5, "a whiffed jab costs %.1f, a landed jab %.1f stamina (net of regen)" % [whiff_paid, hit_paid])
	f = await duel(0.60)
	t = f[1]
	t.practice = true
	t.stats.practice = true
	s0 = t.stats.stamina
	f[0].external_input.strikes.append("RHook")
	await steps(1)
	f[0].external_input.strikes.clear()
	t.external_input.block = true
	await steps(90)
	check(t.stats.stamina < s0 - 3.0 or hits.size() > 0, "blocking / taking a hook drained %.1f stamina" % (s0 - t.stats.stamina))

	print("== C. tired strikes are slower and weaker")
	f = await duel(0.60)
	a = f[0]
	t = f[1]
	t.practice = true
	t.stats.practice = true
	a.stats.stamina = a.stats.stamina_max
	var fresh_time := await action_seconds(a, "LJab")
	await steps(120)
	var fresh_dmg: float = hits[0]["info"]["damage"] if hits.size() > 0 else -1.0
	hits.clear()
	a.stats.stamina = 0.14 * a.stats.stamina_max   # gassed, still able to throw a jab
	check(a.fatigue > 0.5, "stamina 14%% reads as fatigue %.2f" % a.fatigue)
	await steps(30)
	a.stats.stamina = 0.14 * a.stats.stamina_max
	var tired_time := await action_seconds(a, "LJab")
	await steps(120)
	var tired_dmg: float = hits[0]["info"]["damage"] if hits.size() > 0 else -1.0
	check(tired_time > fresh_time * 1.25, "tired jab takes %.2f s vs fresh %.2f s (x%.2f)" % [tired_time, fresh_time, tired_time / fresh_time])
	check(fresh_dmg > 0.0 and tired_dmg > 0.0 and tired_dmg < fresh_dmg * 0.9, "tired jab damage %.2f vs fresh %.2f" % [tired_dmg, fresh_dmg])
	var dmg_a: float = CombatRules.compute_damage(StrikeDB.get_strike("RHook"), {"quality": 1.0})["total"]
	var dmg_b: float = CombatRules.compute_damage(StrikeDB.get_strike("RHook"), {"quality": 1.0, "attacker_fatigue": 0.8})["total"]
	check(dmg_b < dmg_a * 0.8, "damage rule: fatigue 0.8 hook %.2f vs fresh %.2f" % [dmg_b, dmg_a])

	print("== D. a gassed fighter cannot throw power shots")
	f = await duel(0.60)
	a = f[0]
	a.stats.stamina = 0.15 * a.stats.stamina_max
	await throw(a, "RHook")
	await steps(5)
	var hook_started := a.state == Fighter.State.ATTACK
	await steps(100)
	a.stats.stamina = 0.15 * a.stats.stamina_max
	await throw(a, "LJab")
	await steps(2)
	var jab_started := a.state == Fighter.State.ATTACK
	check(not hook_started and jab_started, "at 15%% stamina: hook refused (%s), jab allowed (%s)" % [str(not hook_started), str(jab_started)])
	a.stats.stamina = 0.5 * a.stats.stamina_max
	await steps(100)
	await throw(a, "RHook")
	await steps(2)
	check(a.state == Fighter.State.ATTACK, "at 50%% stamina the hook is thrown again")

	print("== E. a tired guard hangs lower, breathing shows")
	f = await duel(1.6)
	a = f[0]
	a.external_input.block = true
	await steps(90)
	var fresh_hands := hands_above_hip(a)
	a.stats.stamina = 0.12 * a.stats.stamina_max
	for i in 150:
		a.stats.stamina = 0.12 * a.stats.stamina_max
		await steps(1)
	var tired_hands := hands_above_hip(a)
	var fp: Node = a.rig.skeleton.get_node("FatiguePose")
	check(tired_hands < fresh_hands - 0.10, "gloves %.2f m above the hip when tired vs %.2f fresh (drop %.2f)" % [tired_hands, fresh_hands, fresh_hands - tired_hands])
	check(fp.droop > 0.5 and fp.breath > 0.5, "fatigue pose weights droop %.2f breath %.2f" % [fp.droop, fp.breath])
	# breathing: the chest moves over a breath cycle
	var ys := []
	for i in 160:
		a.stats.stamina = 0.12 * a.stats.stamina_max
		await steps(1)
		ys.append(bone_pos(a, "chestUpper").y)
	var lo: float = ys.min()
	var hi: float = ys.max()
	check(hi - lo > 0.006, "chest rises and falls %.1f mm over 1.3 s" % ((hi - lo) * 1000.0))

	print("== F. a tired CPU backs off and does not throw")
	await make_match({"mode": "exhibition", "p1_controller": "cpu", "p2_controller": "dummy", "rounds": 1, "round_seconds": 600.0, "rules": "boxing", "cpu_difficulty": "hard"})
	f = m.get_fighters()
	f[1].external_input = FighterInput.new()
	f[0].global_position = Vector3(-0.45, 0, 0)
	f[1].global_position = Vector3(0.45, 0, 0)
	f[1].practice = true
	f[1].stats.practice = true
	await steps(30)
	var serial0: int = f[0]._serial
	var gap0: float = f[0].gap_to_foe()
	for i in 360:
		f[0].stats.stamina = 0.17 * f[0].stats.stamina_max
		await steps(1)
	check(f[0].gap_to_foe() > gap0 + 0.5 and f[0]._serial == serial0, "tired CPU opened the gap %.2f -> %.2f m and threw %d strikes" % [gap0, f[0].gap_to_foe(), f[0]._serial - serial0])
	# ... and a fresh CPU presses a gassed opponent
	await make_match({"mode": "exhibition", "p1_controller": "cpu", "p2_controller": "dummy", "rounds": 1, "round_seconds": 600.0, "rules": "boxing", "cpu_difficulty": "hard"})
	f = m.get_fighters()
	f[1].external_input = FighterInput.new()
	f[1].practice = true
	f[1].stats.practice = true
	await steps(30)
	var s_a: int = f[0]._serial
	for i in 480:
		f[1].stats.stamina = 0.12 * f[1].stats.stamina_max
		await steps(1)
	check(f[0]._serial - s_a >= 3, "fresh CPU attacks a gassed foe (%d strikes in 4 s)" % (f[0]._serial - s_a))

	print("== G. a clean counter hook rocks")
	f = await duel(0.60)
	a = f[0]
	t = f[1]
	await throw(a, "RHook")
	a.atk["counter"] = true   # as if thrown out of an earned counter window
	await steps(80)
	var rocked_hit: bool = hits.size() >= 1 and hits[0]["info"]["rocked"]
	check(rocked_hit and t.stats.rocked, "counter RHook on a fresh head rocks (damage %.1f, hits %d)" % [hits[0]["info"]["damage"] if hits.size() > 0 else -1.0, hits.size()])
	check(states.has([1, "rocked"]), "'rocked' state signal emitted (HUD tag, camera kick and stun sound hang off it)")
	var cm: bool = CombatRules.should_rock(CombatRules.compute_damage(StrikeDB.get_strike("LHook"), {"quality": 1.0, "counter": true})["total"], 0.0, 100.0, 100.0, true)
	check(cm, "a counter LHook rocks by the rule too")
	f = await duel(0.90)
	await throw(f[0], "LJab")
	await steps(60)
	check(not (hits.size() > 0 and hits[0]["info"]["rocked"]), "a plain jab on a fresh head does not rock")

	print("== H. rock frequency over a 3-minute hard CPU bout")
	await make_match({"mode": "exhibition", "p1_controller": "cpu", "p2_controller": "cpu", "rounds": 1, "round_seconds": 180.0, "rules": "boxing", "cpu_difficulty": "hard"})
	var rocks := [0]
	var kds := [0]
	var first := [-1.0]
	var ended := [false]
	var tclock := [0.0]
	m.fighter_state_changed.connect(func(_i, s):
		if s == "rocked":
			rocks[0] += 1
			if first[0] < 0.0:
				first[0] = tclock[0])
	m.knockdown.connect(func(_i): kds[0] += 1)
	m.match_ended.connect(func(_r): ended[0] = true)
	var smin := [1.0, 1.0]
	var guard_low := 0
	while not ended[0] and tclock[0] < 190.0:
		await steps(1)
		tclock[0] += DT
		for i in 2:
			smin[i] = minf(smin[i], m.get_fighters()[i].stats.stamina_ratio())
	check(rocks[0] >= 1, "%d rocked states in %.0f s of hard CPU fighting (first at %.0f s), %d knockdowns, %d hits landed (%d counters), defences %s %s" % [rocks[0], tclock[0], first[0], kds[0], hits.size(), hits.filter(func(h): return h["info"]["counter"]).size(), m.get_fighters()[0].dm.counts, m.get_fighters()[1].dm.counts])
	# AI polish pass: hard CPUs now pace themselves (bursts of 2-4, then footwork), so round 1 no longer leaves someone gassed
	# below 30 % as a rule (that was the "nonstop 40 strikes/min" bug). Stamina must still be spent (dips well below full) and
	# nobody may be emptied; the non-stop thrower in section A still gasses within 30 s.
	var lo_stam := minf(smin[0], smin[1])
	check(lo_stam < 0.80 and lo_stam > 0.10, "a hard CPU bout spends stamina without emptying anyone (lowest stamina %.0f%%, want 10..80)" % (lo_stam * 100.0))
	check(tclock[0] > 60.0, "the bout did not end inside a minute (%.0f s)" % tclock[0])

	if failures == 0:
		print("PASS: fatigue / rocked frequency")
		quit(0)
	else:
		print("FAIL: %d check(s) failed" % failures)
		quit(1)
