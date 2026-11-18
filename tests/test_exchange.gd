extends SceneTree
# Punch exchange: committed punches continue, trades are decided by timing / line / power, straight punches clash.
# godot --headless --fixed-fps 120 --path . --script res://tests/test_exchange.gd
# Prints PASS/FAIL and exits 0 / 1.

var failures := 0
var m: Match
var hits: Array = []
var clashes: Array = []
var tick := 0
var probe := false


func check(ok: bool, msg: String) -> void:
	if ok:
		print("  ok   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1


func steps(n: int) -> void:
	for i in n:
		await physics_frame
		tick += 1


func make_match() -> void:
	if m != null:
		get_root().remove_child(m)
		m.queue_free()
		await process_frame
	hits.clear()
	clashes.clear()
	m = load("res://scenes/match.tscn").instantiate()
	m.setup({"intro_delay": 0.0, "mode": "exhibition", "rounds": 1, "round_seconds": 600.0, "p1_controller": "dummy", "p2_controller": "dummy"})
	m.hit_landed.connect(func(i, info): hits.append({"i": i, "info": info, "tick": tick}))
	m.clash.connect(func(pos): clashes.append(pos))
	get_root().add_child(m)
	await process_frame


## Two scripted fighters `gap` metres apart; stamina is not the subject here.
func duel(gap: float) -> Array:
	await make_match()
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


## Fighter `a` throws `ta`, `b` throws `tb` `delay` ticks later (negative: b first). Runs `n` ticks.
func exchange(a: Fighter, ta: String, b: Fighter, tb: String, delay: int, n := 150) -> void:
	var first := a if delay >= 0 else b
	var second := b if delay >= 0 else a
	var tf := ta if delay >= 0 else tb
	var ts := tb if delay >= 0 else ta
	a.external_input.strikes.clear()
	b.external_input.strikes.clear()
	first.external_input.strikes.append(tf)
	if delay == 0:
		second.external_input.strikes.append(ts)
	await steps(1)
	first.external_input.strikes.clear()
	second.external_input.strikes.clear()
	if delay > 0 or delay < 0:
		await steps(absi(delay) - 1)
		second.external_input.strikes.append(ts)
		await steps(1)
		second.external_input.strikes.clear()
	for i in n:
		await steps(1)
		if probe:
			print("   t=%d  A %s %.3f %s | B %s %.3f %s" % [tick, a.punch_phase(), a.atk.get("t", -1.0), a.state_name, b.punch_phase(), b.atk.get("t", -1.0), b.state_name])
	if probe:
		for h in hits:
			print("   hit by P%d tick %d %s dmg %.2f q %.2f str %s trade %s won %s ctr %s" % [h["i"] + 1, h["tick"], h["info"]["strike"], h["info"]["damage"], h["info"]["quality"], h["info"]["strength"], h["info"].get("trade"), h["info"].get("trade_won"), h["info"]["counter"]])


func hit_by(i: int) -> Dictionary:
	for h in hits:
		if h["i"] == i:
			return h["info"]
	return {}


func settle(f: Array) -> void:
	await steps(200)
	for x in f:
		x.stats.head = 100.0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	probe = "probe" in args
	if probe:
		var f: Array = await duel(float(args[1]) if args.size() > 1 else 0.9)
		await exchange(f[0], args[2], f[1], args[3], int(args[4]))
		quit(0)
		return
	const GAP := 0.60   # was 0.8: contact-only hits, the literal (unaimed) hook only touches a head this close
	var f: Array

	# control: the same hook thrown at an idle foe
	f = await duel(GAP)
	await exchange(f[0], "RHook", f[1], "", 0)
	var hook_alone: Dictionary = hit_by(0)
	var jab_alone: Dictionary = {}
	f = await duel(GAP)
	await exchange(f[0], "", f[1], "LJab", 0)
	jab_alone = hit_by(1)
	print("== control: RHook alone %.2f   LJab alone %.2f" % [float(hook_alone.get("damage", 0.0)), float(jab_alone.get("damage", 0.0))])
	check(not hook_alone.is_empty() and not jab_alone.is_empty() and not bool(hook_alone["trade"]), "control punches land and are not trades")
	check(f[0].punch_phase() == "none", "punch_phase is none when idle")

	print("== a. a committed hook continues and lands after taking a jab")
	f = await duel(GAP)
	await exchange(f[0], "RHook", f[1], "LJab", 6)   # the hook goes first; the quicker jab lands while the hook's hand is already released
	var h_jab := hit_by(1)
	var h_hook := hit_by(0)
	check(not h_jab.is_empty() and not h_hook.is_empty(), "both punches landed")
	check(f[0].stats.head < 100.0 and f[1].stats.head < 100.0, "both took damage")
	check(float(h_hook.get("damage", 99.0)) < float(hook_alone["damage"]) * 0.85, "the hook landed weaker than alone (%.2f vs %.2f)" % [float(h_hook.get("damage", 0.0)), float(hook_alone["damage"])])
	check(bool(h_hook.get("trade", false)) and bool(h_jab.get("trade", false)), "reported as a trade")

	print("== b. a jab in the foe's startup interrupts it and counts as a counter")
	f = await duel(GAP)
	await exchange(f[0], "LJab", f[1], "RHook", 4, 60)
	var hb := hit_by(0)
	check(not hb.is_empty() and bool(hb["counter"]), "the jab is a counter")
	check(hit_by(1).is_empty(), "the interrupted hook never lands")
	check(f[1].state == Fighter.State.HIT or f[1].state == Fighter.State.IDLE, "the foe's punch was cut off (state %s)" % f[1].state_name)

	print("== c. cross vs wide hook at the same moment: the cross wins the trade")
	f = await duel(GAP)
	await exchange(f[0], "RJab", f[1], "LHook~wide", 0)
	var hc := hit_by(0)
	var hw := hit_by(1)
	check(not hc.is_empty() and not hw.is_empty(), "both landed")
	check(bool(hc.get("trade_won", false)) and bool(hw.get("trade", false)) and not bool(hw.get("trade_won", true)), "cross won, hook lost")

	print("== d. hook vs hook: the one thrown earlier wins")
	f = await duel(GAP)
	await exchange(f[0], "LHook", f[1], "LHook", 4)
	check(bool(hit_by(0).get("trade_won", false)) and (hit_by(1).is_empty() or not bool(hit_by(1).get("trade_won", true))), "P1 (earlier) won")
	var early_dmg := float(hit_by(0).get("damage", 0.0))
	f = await duel(GAP)
	await exchange(f[0], "LHook", f[1], "LHook", -4)
	check(bool(hit_by(1).get("trade_won", false)) and (hit_by(0).is_empty() or not bool(hit_by(0).get("trade_won", true))), "P2 (earlier) won")
	check(early_dmg > float(hit_by(0).get("damage", 0.0)), "the winner's hook does more (%.2f vs %.2f)" % [early_dmg, float(hit_by(0).get("damage", 0.0))])

	print("== e. two jabs at the same time clash: no damage")
	f = await duel(GAP)
	await exchange(f[0], "LJab", f[1], "LJab", 0)
	check(clashes.size() == 1, "one clash signal (%d)" % clashes.size())
	check(hits.is_empty() and f[0].stats.head == 100.0 and f[1].stats.head == 100.0, "nobody was hurt")
	check(f[0].state == Fighter.State.IDLE and f[1].state == Fighter.State.IDLE, "both recovered")

	print("== f. a knockdown-level shot still cuts the punch off")
	f = await duel(GAP)
	f[1].stats.head = 2.0   # the hook alone floors him (head <= 0.5 forces the knockdown; the chance roll depends on contact quality)
	await exchange(f[0], "RHook", f[1], "LJab", 3, 40)
	check(f[1].stats.knockdowns == 1 or f[1].state in [Fighter.State.FALL, Fighter.State.COUNT, Fighter.State.DOWN], "foe was floored (%s)" % f[1].state_name)
	check(f[1].atk.is_empty(), "its punch is gone")

	print("== g. walking into a punch costs more, backing away costs less")
	var dmg := {}
	var pure := {}
	for mode in ["still", "in", "away"]:
		var start := 0.85 if mode == "still" else (1.5 if mode == "in" else 0.78)
		f = await duel(start)
		var inp: FighterInput = f[1].external_input
		inp.move = Vector2(-1, 0) if mode == "in" else (Vector2(1, 0) if mode == "away" else Vector2.ZERO)
		var n := 0
		while mode == "in" and f[0].gap_to_foe() > 1.0 and n < 300:
			await steps(1)
			n += 1
		var gap0: float = f[0].gap_to_foe()
		f[0].external_input.strikes.append("LJab")
		await steps(1)
		f[0].external_input.strikes.clear()
		await steps(40)
		dmg[mode] = float(hit_by(0).get("damage", 0.0))
		var q := float(hit_by(0).get("quality", 0.0))
		pure[mode] = dmg[mode] / (0.45 + 0.55 * q)   # CombatRules: damage x (0.45 + 0.55 q); q (how centred) depends on where the walker meets the glove
		print("   %s: gap at throw %.2f, quality %.2f, speed %.2f, damage before quality %.2f" % [mode, gap0, q, float(hit_by(0).get("speed", 0.0)), pure[mode]])
	print("   still %.2f  in %.2f  away %.2f" % [dmg["still"], dmg["in"], dmg["away"]])
	check(dmg["still"] > 0.0 and pure["in"] > pure["still"] * 1.08, "walking into the jab hurts more (same centring)")
	check(dmg["away"] < dmg["still"] * 0.95, "backing away from it hurts less (or it falls short)")

	print("PASS" if failures == 0 else "FAIL (%d)" % failures)
	quit(failures)
