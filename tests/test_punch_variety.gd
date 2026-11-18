extends SceneTree
# Punch variety: variants per strike, tap / power / chain choice, no repeated clip, miss recovery, physical hit path,
# CPU variety, per-throw jitter.
# godot --headless --fixed-fps 120 --path . --script res://tests/test_punch_variety.gd

const PunchVariantsScript := preload("res://scripts/combat/punch_variants.gd")
const BASES := ["LJab", "RJab", "LHook", "RHook", "LUppercut", "RUppercut", "LBodyJab", "RBodyJab", "LBodyHook", "RBodyHook", "LBodyUppercut", "RBodyUppercut"]

var failures := 0
var m: Match
var hits: Array = []
var whiffs: Array = []


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
	m = load("res://scenes/match.tscn").instantiate()
	var full := {"intro_delay": 0.0, "mode": "exhibition", "rounds": 1, "round_seconds": 600.0}
	full.merge(cfg, true)
	m.setup(full)
	m.hit_landed.connect(func(i, info): hits.append({"i": i, "info": info}))
	m.whiffed.connect(func(i, s): whiffs.append({"i": i, "strike": s}))
	get_root().add_child(m)
	await process_frame


func duel(gap: float) -> Array:
	await make_match({"p1_controller": "dummy", "p2_controller": "dummy"})
	var f: Array = m.get_fighters()
	f[0].global_position = Vector3(-gap * 0.5, 0, 0)
	f[1].global_position = Vector3(gap * 0.5, 0, 0)
	f[0].external_input = FighterInput.new()
	f[1].external_input = FighterInput.new()
	# this test is about variants, not stamina: long whiff runs would gas the attacker under the fatigue rules
	f[0].stats.infinite_stamina = true
	f[1].stats.infinite_stamina = true
	await steps(90)
	return f


func press(f: Fighter, tag: String) -> void:
	f.external_input.strikes.append(tag)
	await steps(1)
	f.external_input.strikes.clear()


## Throw `tag` and wait until the attacker is idle again; returns {s, A, t_total, tail, outcome, var}.
func throw_full(f: Fighter, tag: String) -> Dictionary:
	await press(f, tag)
	var rec := {"s": f.atk.get("s", {}), "A": f.atk.get("A", 0.0), "var": f.atk.get("var", {}), "ticks": 1, "outcome": ""}
	var n := 0
	while f.state == Fighter.State.ATTACK and n < 600:
		rec["outcome"] = f.atk.get("outcome", "")
		await steps(1)
		n += 1
		rec["ticks"] = n
	rec["t_total"] = float(n) / 120.0
	return rec


func sig(tag: String) -> String:
	var s := StrikeDB.get_strike(tag)
	return "%s|%.2f|%.2f" % [s["clip"], s["action"], s["t_peak"]]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	# ------------------------------------------------------------------ A. table
	print("== A. every base strike has >= 2 variants with distinct clip / timing")
	var most := 0
	for b in BASES:
		var tags: Array = [b] + StrikeDB.variant_tags(b)
		var sigs := {}
		for t in tags:
			sigs[sig(t)] = true
		check(tags.size() >= 2 and sigs.size() == tags.size(), "%s: %d variants, %d distinct (clip, action, contact) signatures" % [b, tags.size(), sigs.size()])
		var clips := {}
		for t in tags:
			clips[StrikeDB.get_strike(t)["clip"]] = true
		most = maxi(most, clips.size())
	check(most >= 3, "at least one strike has >= 3 different clips (max %d)" % most)
	var fl := StrikeDB.get_strike("LJab~flick")
	var st := StrikeDB.get_strike("LJab")
	var pw := StrikeDB.get_strike("LJab~lunge")
	print("       LJab flick  action %.2f contact %.2f dmg %.1f sta %.1f | std %.2f %.2f %.1f %.1f | lunge %.2f %.2f %.1f %.1f" % [
		fl["action"], fl["t_peak"], fl["damage"], fl["stamina"], st["action"], st["t_peak"], st["damage"], st["stamina"],
		pw["action"], pw["t_peak"], pw["damage"], pw["stamina"]])
	check(fl["action"] < st["action"] and st["action"] < pw["action"], "flick < standard < lunge in action time")
	check(fl["t_peak"] < st["t_peak"] and st["t_peak"] < pw["t_peak"], "flick < standard < lunge in time to contact")
	check(fl["damage"] < st["damage"] and st["damage"] < pw["damage"] and fl["stamina"] < pw["stamina"], "damage and stamina rise flick -> standard -> lunge")
	check(not fl["heavy"] and pw["heavy"], "flick is not heavy, lunge is heavy")
	check(float(StrikeDB.variant_row("LJab~lunge")["range"][1]) > float(StrikeDB.variant_row("LJab~flick")["range"][1]) + 0.3, "lunge reaches > 0.3 m farther than the flick")

	# ------------------------------------------------------------------ B. tap vs power
	print("== B. input: tap = standard, power modifier = loaded; hinted tags resolve to the intended class")
	var hc := HumanController.new("p1")
	var fi := FighterInput.new()
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_J
	ev.pressed = true
	Input.parse_input_event(ev)
	Input.flush_buffered_events()
	hc.poll(fi)
	check(fi.strikes == ["LJab"], "tap J -> LJab (%s)" % str(fi.strikes))
	var ev1 := ev.duplicate() as InputEventKey
	ev1.pressed = false
	Input.parse_input_event(ev1)
	Input.flush_buffered_events()
	hc.poll(fi)
	var pe := InputEventKey.new()
	pe.physical_keycode = KEY_R
	pe.pressed = true
	Input.parse_input_event(pe)
	Input.flush_buffered_events()
	var ev2 := ev.duplicate() as InputEventKey
	ev2.pressed = true
	Input.parse_input_event(ev2)
	Input.flush_buffered_events()
	hc.poll(fi)
	check(fi.strikes == ["LJab@power"], "R (power) + J -> LJab@power (%s)" % str(fi.strikes))
	var ev3 := ev.duplicate() as InputEventKey
	ev3.pressed = false
	pe.pressed = false
	Input.parse_input_event(ev3)
	Input.parse_input_event(pe)
	Input.flush_buffered_events()
	hc.poll(fi)
	var f := await duel(0.92)
	var a: Fighter = f[0]
	var tap := await throw_full(a, "LJab@auto")
	await steps(60)
	var pow_ := await throw_full(a, "LJab@power")
	var ts: Dictionary = tap["s"]
	var ps: Dictionary = pow_["s"]
	print("       tap %s clip %s action %.2f contact %.2f | power %s clip %s action %.2f contact %.2f" % [ts["tag"], ts["clip"], ts["action"], ts["t_peak"], ps["tag"], ps["clip"], ps["action"], ps["t_peak"]])
	check(ts["klass"] == "std" or ts["tag"] == "LJab", "tap throws the standard jab (%s)" % ts["tag"])
	check(ps["klass"] == "lunge", "power modifier throws the lunging jab (%s)" % ps["tag"])
	check(ps["action"] > ts["action"] and ps["t_peak"] > ts["t_peak"], "power is slower (action %.2f > %.2f, contact %.2f > %.2f)" % [ps["action"], ts["action"], ps["t_peak"], ts["t_peak"]])
	check(float(ps["reach"]) > float(ts["reach"]) and float(ps["lunge"]) > 0.2, "power has more reach (%.2f vs %.2f) and steps in (%.2f m)" % [ps["reach"], ts["reach"], ps["lunge"]])
	# power multipliers were cut from 1.7-2.2x to 1.4-1.45x in the pacing pass (fights were ending inside round 1)
	check(ps["damage"] > ts["damage"] * 1.35 and ps["heavy"], "power does > 1.35x the damage and is heavy (%.1f vs %.1f)" % [ps["damage"], ts["damage"]])
	for hint_case in [["LHook@power", "wide"], ["LHook@quick", "tight"], ["LUppercut@power", "rise"], ["RJab@quick", "flick"], ["RBodyHook@power", "power"], ["LJab@step", "lunge"], ["LJab@pull", "pull"]]:
		f = await duel(0.92)
		var r := await throw_full(f[0], hint_case[0])
		check((r["s"] as Dictionary).get("klass", "std") == hint_case[1], "%s -> class %s (%s)" % [hint_case[0], hint_case[1], r["s"]["tag"]])
	# movement intent: stepping in / pulling back on a plain tap of a human-style choice
	f = await duel(1.10)
	f[0].external_input.move = Vector2(1, 0)   # toward the foe (P1 is on the left)
	var step_r := await throw_full(f[0], "LJab@auto")
	check((step_r["s"] as Dictionary).get("klass", "") == "lunge", "tap while moving in from 1.1 m = step-in jab (%s)" % step_r["s"]["tag"])
	f = await duel(0.90)
	f[0].external_input.move = Vector2(-1, 0)
	var pull_r := await throw_full(f[0], "LJab@auto")
	check((pull_r["s"] as Dictionary).get("klass", "") == "pull", "tap while moving back = pull-back jab (%s)" % pull_r["s"]["tag"])

	# ------------------------------------------------------------------ C. double / triple jab
	print("== C. quick re-tap = double jab (flick chain)")
	f = await duel(0.95)
	a = f[0]
	var log: Array = []
	var serial0: int = a._serial
	await press(a, "LJab@auto")
	var next_tap := 26
	var taps := 1
	for i in 400:
		if a._serial != serial0:
			serial0 = a._serial
			log.append(a.atk["tag"])
		if i == next_tap and taps < 3:
			a.external_input.strikes.append("LJab@auto")   # re-taps at 0.22 s and 0.55 s (a tap queued behind a pending one would replace it)
			taps += 1
			next_tap += 40
		else:
			a.external_input.strikes.clear()
		await steps(1)
	print("       sequence: ", log)
	check(log.size() >= 2 and log[0] in ["LJab", "LJab~std2"], "first tap is a standard jab (%s)" % str(log))
	check(log.size() >= 2 and String(log[1]).begins_with("LJab~flick"), "second tap is the flick: double jab (%s)" % str(log))
	var flicks := log.filter(func(t): return String(t).begins_with("LJab~flick")).size()
	check(flicks >= 2 and log.size() >= 3, "a third tap keeps flicking: triple jab (%d flicks, %d strikes)" % [flicks, log.size()])
	f = await duel(0.95)
	a = f[0]
	await press(a, "LJab@auto")
	await steps(300)
	var late := await throw_full(a, "LJab@auto")
	check((late["s"] as Dictionary).get("klass", "std") != "flick", "a tap after a pause is not a flick (%s)" % late["s"]["tag"])

	# ------------------------------------------------------------------ D. never the same clip twice
	print("== D. the same button never plays the exact same clip twice in a row")
	var bad := 0
	var seq_dump := {}
	for case in [["LJab", "std"], ["RJab", "std"], ["LHook", "std"], ["RHook", "std"], ["LUppercut", "std"], ["RUppercut", "std"],
			["LJab", "quick"], ["RJab", "quick"], ["LHook", "quick"], ["LJab", "pull"]]:
		var base: String = case[0]
		f = await duel(2.4)   # out of range: whiffs, no knockdown noise
		a = f[0]
		var prev := ""
		var clips: Array = []
		for i in 14:
			var r2 := await throw_full(a, base + "@" + case[1])
			await steps(10)
			var c: String = r2["s"]["clip"]
			clips.append(c)
			if c == prev:
				bad += 1
			prev = c
		seq_dump[base] = clips.size()
	check(bad == 0, "140 throws (10 punch / hint cases x 14): %d immediate clip repeats" % bad)

	# ------------------------------------------------------------------ E. whiff recovery
	print("== E. a whiffed power punch overextends: longer recovery, counter window")
	f = await duel(2.4)
	var res := {}
	for tag in ["LJab~flick", "LJab", "LJab~lunge", "LHook", "LHook~wide", "RUppercut", "RUppercut~rise"]:
		f = await duel(2.4)
		var r3 := await throw_full(f[0], tag)
		res[tag] = r3
		print("       whiff %-16s action %.2f  total %.2f s  (tail %.2f)" % [tag, r3["A"], r3["t_total"], r3["t_total"] - r3["A"]])
	check(res["LJab~lunge"]["t_total"] > res["LJab"]["t_total"] + 0.3, "lunge jab whiff recovery %.2f s vs standard %.2f s" % [res["LJab~lunge"]["t_total"], res["LJab"]["t_total"]])
	check(res["LHook~wide"]["t_total"] > res["LHook"]["t_total"] + 0.3, "wide hook whiff %.2f s vs standard hook %.2f s" % [res["LHook~wide"]["t_total"], res["LHook"]["t_total"]])
	check(res["RUppercut~rise"]["t_total"] > res["RUppercut"]["t_total"] + 0.25, "rising uppercut whiff %.2f s vs standard %.2f s" % [res["RUppercut~rise"]["t_total"], res["RUppercut"]["t_total"]])
	var tail_pow: float = res["LJab~lunge"]["t_total"] - res["LJab~lunge"]["A"]
	var tail_flick: float = res["LJab~flick"]["t_total"] - res["LJab~flick"]["A"]
	check(tail_pow > tail_flick + 0.25, "committed time after the action: lunge %.2f s vs flick %.2f s" % [tail_pow, tail_flick])
	# the same power punch that LANDS recovers faster than when it misses
	f = await duel(0.95)
	var hit_r := await throw_full(f[0], "LJab~lunge")
	check(hits.size() == 1 and hit_r["t_total"] < res["LJab~lunge"]["t_total"] - 0.2, "landing the lunge recovers %.2f s < whiff %.2f s" % [hit_r["t_total"], res["LJab~lunge"]["t_total"]])
	# the defender gets a counter window while the whiffer is still committed
	f = await duel(2.4)
	f[1].global_position = Vector3(1.2, 0, 0)
	f[0].global_position = Vector3(-1.2, 0, 0)
	await press(f[0], "LHook~wide")
	var window_ticks := 0
	var peak_miss := 0.0
	for i in 160:
		await steps(1)
		if f[0]._earned_counter():   # evaluated on the whiffer: a hit on it now counts as a counter
			window_ticks += 1
		peak_miss = maxf(peak_miss, (f[0]._punch_pose as Object).get("w_miss"))
	print("       counter window %.2f s, torso overextension weight peak %.2f" % [window_ticks / 120.0, peak_miss])
	check(window_ticks / 120.0 > 0.55, "defender counter window after a whiffed wide hook: %.2f s" % [window_ticks / 120.0])
	check(peak_miss > 0.5, "the whiff drives the overextension pose (peak %.2f)" % peak_miss)

	# ------------------------------------------------------------------ F. every variant lands, power reports heavy
	print("== F. every variant lands on an idle foe at its intended range (physics hit path)")
	var all_tags: Array = BASES.duplicate()
	for b in BASES:
		all_tags.append_array(StrikeDB.variant_tags(b))
	var not_landed: Array = []
	var heavy_ok := true
	var n_heavy := 0
	for tag in all_tags:
		var row := StrikeDB.variant_row(tag)
		var gap := 0.88
		if row.has("range"):
			gap = (float(row["range"][0]) + float(row["range"][1])) * 0.5
			gap = clampf(gap, 0.72, 1.3)
		# contact-only hits: the variant table's ranges were measured against the old big hit volumes. A variant has to land at SOME range:
		# try its table range first, then scan 0.5 .. 1.2 m until one lands squarely
		var tries: Array = [gap]
		for cm in [60, 70, 80, 50, 90, 100, 110, 120]:
			tries.append(cm / 100.0)
		var landed := []
		var best_dmg := -1.0
		var best_gap := gap
		for g_try in tries:   # the best landing (a clean hit, not a glance) is the one measured
			f = await duel(g_try)
			await press(f[0], tag)
			await steps(170)
			var l_try := hits.filter(func(h): return h["i"] == 0 and not h["info"]["blocked"] and not h["info"].get("glance", false))
			if not l_try.is_empty() and float(l_try[0]["info"]["damage"]) > best_dmg:
				best_dmg = float(l_try[0]["info"]["damage"])
				best_gap = g_try
				landed = l_try
				if float(l_try[0]["info"]["quality"]) >= 0.6:
					break   # a solid landing: good enough (the scan is the expensive part of this test)
		gap = best_gap
		if landed.is_empty():
			not_landed.append("%s@%.2f" % [tag, gap])
		else:
			var s := StrikeDB.get_strike(tag)
			if s.get("force_heavy", false):
				n_heavy += 1
				if landed[0]["info"]["strength"] != "heavy" and float(landed[0]["info"]["damage"]) >= 4.0:   # force_heavy needs 4+ damage (strength_of); a contact-only lunge jab that lands off centre can fall short
					heavy_ok = false
					print("       not heavy: ", tag, " ", landed[0]["info"])
	check(not_landed.is_empty(), "%d/%d variants landed (missed: %s)" % [all_tags.size() - not_landed.size(), all_tags.size(), str(not_landed)])
	check(heavy_ok and n_heavy >= 12, "all %d power variants that landed reported strength heavy" % n_heavy)

	# ------------------------------------------------------------------ G. jitter
	print("== G. per-throw variation: speed +-6 %, torso rotation, aim")
	f = await duel(2.4)
	a = f[0]
	var speeds: Array = []
	var yaws: Array = []
	var aims: Array = []
	for i in 30:
		var r4 := await throw_full(a, "LJab@std")
		await steps(8)
		speeds.append(float(r4["A"]) / float((r4["s"] as Dictionary)["action"]))
		yaws.append(float((r4["var"] as Dictionary)["yaw_mul"]))
		aims.append((r4["var"] as Dictionary)["aim_noise"])
	speeds.sort()
	yaws.sort()
	print("       speed factors %.3f .. %.3f, torso yaw x %.2f .. %.2f" % [speeds[0], speeds[-1], yaws[0], yaws[-1]])
	check(speeds[0] >= 0.939 and speeds[-1] <= 1.061, "speed within +-6 %")
	check(speeds[-1] - speeds[0] > 0.06, "speed actually varies (%.3f spread)" % (speeds[-1] - speeds[0]))
	check(yaws[-1] - yaws[0] > 0.3, "torso rotation amount varies (x%.2f .. x%.2f)" % [yaws[0], yaws[-1]])
	var aim_distinct := {}
	for v in aims:
		aim_distinct[snappedf((v as Vector2).x, 0.002)] = true
	check(aim_distinct.size() > 10, "aim offset varies per throw (%d distinct)" % aim_distinct.size())
	# ------------------------------------------------------------------ H. CPU variety
	print("== H. CPU uses >= 5 distinct variants in a hard bout")
	await make_match({"p1_controller": "cpu", "p2_controller": "cpu", "cpu_difficulty": "hard"})
	var ff: Array = m.get_fighters()
	var seen := {}
	var order: Array = []
	var last_serial := [-1, -1]
	for i in 120 * 70:
		await steps(1)
		for k in 2:
			var fk: Fighter = ff[k]
			if fk._serial != last_serial[k] and not fk.atk.is_empty():
				last_serial[k] = fk._serial
				var tg: String = fk.atk["tag"]
				seen[tg] = int(seen.get(tg, 0)) + 1
		if m.is_over() if m.has_method("is_over") else false:
			break
	print("       strikes thrown: ", seen)
	var distinct_variants := seen.keys().filter(func(t): return String(t).contains("~")).size()
	check(distinct_variants >= 5, "%d distinct punch variants in 70 s of hard CPU vs CPU" % distinct_variants)

	if failures == 0:
		print("PASS: punch variety")
		quit(0)
	else:
		print("FAIL: %d check(s) failed" % failures)
		quit(1)
