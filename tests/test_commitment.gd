extends SceneTree
# Punch commitment: no guard / movement cancel before the retraction is done, whiff + block penalties, open window
# (counter bonus), uppercut punish, per-punch durations.
# godot --headless --fixed-fps 120 --path . --script res://tests/test_commitment.gd

const CommitmentScript := preload("res://scripts/combat/commitment.gd")
const DT := 1.0 / 120.0

var failures := 0
var m: Match
var hits: Array = []


func check(ok: bool, msg: String) -> void:
	if ok:
		print("  ok   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1


func steps(n: int) -> void:
	for i in n:
		await physics_frame


func duel(gap: float) -> Array:
	if m != null:
		get_root().remove_child(m)
		m.queue_free()
		await process_frame
	hits.clear()
	m = load("res://scenes/match.tscn").instantiate()
	m.setup({"intro_delay": 0.0, "mode": "exhibition", "rounds": 1, "round_seconds": 600.0, "p1_controller": "dummy", "p2_controller": "dummy"})
	m.hit_landed.connect(func(i, info): hits.append({"i": i, "info": info}))
	get_root().add_child(m)
	await process_frame
	var f: Array = m.get_fighters()
	f[0].global_position = Vector3(-gap * 0.5, 0, 0)
	f[1].global_position = Vector3(gap * 0.5, 0, 0)
	for x in f:
		x.external_input = FighterInput.new()
		x.stats.infinite_stamina = true
		x.practice = false
	await steps(90)
	hits.clear()
	return f


func throw(f: Fighter, tag: String) -> void:
	f.external_input.strikes.append(tag)
	await steps(1)
	f.external_input.strikes.clear()


func hit_by(i: int) -> Dictionary:
	for h in hits:
		if h["i"] == i:
			return h["info"]
	return {}


## Seconds after `tag` starts until `pred` first holds (or 3 s).
func time_until(f: Fighter, pred: Callable) -> float:
	for i in 360:
		await steps(1)
		if pred.call():
			return (i + 2) * DT
	return 3.0


func lock_of(tag: String) -> float:
	var s := StrikeDB.get_strike(tag)
	return CommitmentScript.lock_time(s, float(s["action"]))


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var f: Array

	print("== durations (guard / feet come back after a clean punch)")
	var want := {"LJab": [0.34, 0.44], "RJab": [0.50, 0.60], "LHook": [0.52, 0.64], "RHook": [0.52, 0.64], "LUppercut": [0.57, 0.70], "RUppercut": [0.57, 0.70],
		"LBodyJab": [0.38, 0.48], "RBodyHook": [0.58, 0.72], "RBodyUppercut": [0.62, 0.78],
		"LJab~lunge": [0.46, 0.60], "RHook~wide": [0.72, 0.92], "RUppercut~rise": [0.76, 0.96], "RBodyHook~power": [0.80, 1.00]}
	for tag in want:
		var l := lock_of(tag)
		check(l >= want[tag][0] and l <= want[tag][1], "%s lock %.2f s in [%.2f, %.2f]" % [tag, l, want[tag][0], want[tag][1]])
	check(lock_of("RHook~wide") > lock_of("RHook") * 1.25, "a loaded hook is >= 1.25x a normal one")
	check(CommitmentScript.miss_extra(StrikeDB.get_strike("LJab")) < CommitmentScript.miss_extra(StrikeDB.get_strike("LHook")) \
		and CommitmentScript.miss_extra(StrikeDB.get_strike("LHook")) < CommitmentScript.miss_extra(StrikeDB.get_strike("LUppercut")) \
		and CommitmentScript.miss_extra(StrikeDB.get_strike("LUppercut")) < CommitmentScript.miss_extra(StrikeDB.get_strike("RHook~wide")), "whiff penalty: jab < hook < uppercut < power")

	print("== block cannot cancel a hook before recovery ends")
	f = await duel(0.85)
	var hook_lock := lock_of("LHook")
	await throw(f[0], "LHook")
	f[0].external_input.block = true
	var t_guard: float = await time_until(f[0], func(): return f[0].guard_on)
	t_guard += DT
	print("   guard raised %.3f s after the throw (lock %.3f)" % [t_guard, hook_lock])
	check(t_guard >= hook_lock - 0.02, "guard comes back no earlier than the end of the retraction (%.2f >= %.2f)" % [t_guard, hook_lock])
	check(t_guard <= StrikeDB.get_strike("LHook")["action"] + 0.2, "... and not absurdly late (%.2f)" % t_guard)

	print("== movement does not cancel a hook")
	f = await duel(0.85)
	await throw(f[0], "LHook")
	f[0].external_input.move = Vector2(0, -1)
	var t_free: float = await time_until(f[0], func(): return f[0].state != Fighter.State.ATTACK)
	t_free += DT
	print("   left ATTACK after %.3f s" % t_free)
	check(t_free >= hook_lock - 0.02, "walking input does not end the punch early (%.2f >= %.2f)" % [t_free, hook_lock])

	print("== a whiffed hook leaves the thrower open, and a punch landing then is a counter")
	f = await duel(2.4)   # far out of reach: pure whiff
	await throw(f[0], "RHook")
	var open_ticks := 0
	var landed := false
	var counter_info := {}
	var launched := false
	for i in 260:
		await steps(1)
		if f[0].state == Fighter.State.ATTACK and CommitmentScript.is_open(f[0].atk):
			open_ticks += 1
			if not launched and open_ticks >= 6:
				launched = true
				f[1].global_position = f[0].global_position + Vector3(0.85, 0, 0)   # foe steps in during the overextension
				await throw(f[1], "RJab")
	counter_info = hit_by(1)
	print("   open %.3f s, counter info %s" % [open_ticks * DT, str(counter_info.get("damage", "-"))])
	check(open_ticks * DT >= 0.35, "the whiffed hook is open for >= 0.35 s (%.2f)" % (open_ticks * DT))
	check(not counter_info.is_empty() and bool(counter_info.get("counter", false)) and bool(counter_info.get("open", false)), "the jab that lands is an open-window counter")
	var plain: Dictionary
	f = await duel(0.85)
	await throw(f[1], "RJab")
	await steps(90)
	plain = hit_by(1)
	check(not plain.is_empty() and float(counter_info.get("damage", 0.0)) >= float(plain.get("damage", 99.0)) * 1.25, "counter damage %.2f >= 1.25x plain %.2f" % [float(counter_info.get("damage", 0.0)), float(plain.get("damage", 0.0))])

	print("== a blocked punch recovers slower than a clean one")
	f = await duel(0.85)
	await throw(f[0], "LJab")
	var t_clean: float = await time_until(f[0], func(): return f[0].state != Fighter.State.ATTACK)
	f = await duel(0.85)
	f[1].external_input.block = true
	await steps(30)
	await throw(f[0], "LJab")
	var blocked_hit := false
	var t_block: float = await time_until(f[0], func(): return f[0].state != Fighter.State.ATTACK)
	blocked_hit = bool(hit_by(0).get("blocked", false))
	print("   clean %.3f s, blocked %.3f s (blocked hit %s)" % [t_clean, t_block, str(blocked_hit)])
	check(blocked_hit, "the jab was blocked")
	check(t_block >= t_clean + 0.03, "the blocked punch recovers slower (%.2f vs %.2f)" % [t_block, t_clean])

	print("== uppercut punishes a low / forward head (inside range 0.46 m: contact-only hits, an uppercut only reaches a head that close; at 0.85 it goes into the body)")
	f = await duel(0.46)
	check(not f[1].head_low_or_forward(), "idle fighter: head not low")
	f[1].external_input.duck = true
	await steps(40)
	check(f[1].state == Fighter.State.CROUCH and f[1].head_low_or_forward(), "crouched fighter: head low")
	f = await duel(0.46)
	await throw(f[1], "RBodyHook")
	await steps(22)   # the thrower's lead glove covers the chin while the body hook is held out: the uppercut lands as he comes back
	check(f[1].head_low_or_forward(), "body-shot thrower: head forward")
	await throw(f[0], "RUppercut")
	await steps(120)
	var up := hit_by(0)
	print("   uppercut into body-shot thrower: %s" % str(up))
	check(not up.is_empty() and bool(up.get("punish", false)), "uppercut landing on a body-shot thrower is a punish")
	f = await duel(0.85)
	await throw(f[0], "RUppercut")
	await steps(120)
	var up_plain := hit_by(0)
	check(not up_plain.is_empty() and not bool(up_plain.get("punish", false)), "uppercut on an idle fighter is not")
	var us := StrikeDB.get_strike("RUppercut")
	var d_plain: float = CombatRules.compute_damage(us, {"counter": false})["total"]
	var d_pun: float = CombatRules.compute_damage(us, {"counter": true, "punish": true})["total"]
	var d_open: float = CombatRules.compute_damage(us, {"counter": true, "open": true})["total"]
	check(d_pun >= d_plain * 1.45 and d_open >= d_plain * 1.3 and d_pun > d_open, "damage maths: punish x%.2f, open x%.2f, plain 1" % [d_pun / d_plain, d_open / d_plain])

	print("PASS" if failures == 0 else "FAIL (%d)" % failures)
	quit(0 if failures == 0 else 1)
