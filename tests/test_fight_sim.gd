extends SceneTree
# Integration test: instances scenes/match.tscn and drives fighters through the real physics/hit-area path.
# godot --headless --path . --script res://tests/test_fight_sim.gd      (~2 min wall clock; add --fixed-fps 120 to run much faster)

var failures := 0
var m: Match
var hits: Array = []
var clash_times: Array = []   ## exchange: glove clashes (no damage) count as engagement
var whiffs: Array = []
var knockdowns: Array = []
var counts: Array = []
var results: Array = []
var states: Array = []
var round_events: Array = []
var paused_pos: Array = []
var timer_events: Array = []


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
	clash_times.clear()
	whiffs.clear()
	knockdowns.clear()
	counts.clear()
	results.clear()
	states.clear()
	round_events.clear()
	timer_events.clear()
	m = load("res://scenes/match.tscn").instantiate()
	var full := {"intro_delay": 0.0}   # most checks want a live bout from tick 0 (section I tests the intro)
	full.merge(cfg, true)
	m.setup(full)
	m.hit_landed.connect(func(i, info): hits.append({"i": i, "info": info}))
	m.whiffed.connect(func(i, s): whiffs.append({"i": i, "strike": s}))
	m.clash.connect(func(_p): clash_times.append(Engine.get_physics_frames()))
	m.knockdown.connect(func(i): knockdowns.append(i))
	m.count_tick.connect(func(i, n): counts.append([i, n]))
	m.match_ended.connect(func(r): results.append(r))
	m.fighter_state_changed.connect(func(i, s): states.append([i, s]))
	m.round_started.connect(func(r): round_events.append(r))
	m.timer_changed.connect(func(t): timer_events.append(t))
	get_root().add_child(m)
	await process_frame


## two scripted dummies facing each other `gap` metres apart (centre to centre)
func duel(gap: float) -> Array:
	await make_match({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy", "rounds": 1, "round_seconds": 120.0})
	var f: Array = m.get_fighters()
	f[0].global_position = Vector3(-gap * 0.5, 0, 0)
	f[1].global_position = Vector3(gap * 0.5, 0, 0)
	f[0].external_input = FighterInput.new()
	f[1].external_input = FighterInput.new()
	await steps(90)
	return f


func throw(fighter: Fighter, tag: String) -> void:
	fighter.external_input.strikes.append(tag)
	await steps(1)
	fighter.external_input.strikes.clear()


func _initialize() -> void:
	print("== A. jab lands through the Area3D hit path")
	var f := await duel(0.90)
	var p2_head := (f[1] as Fighter).stats.head
	await throw(f[0], "LJab")
	var stam_after: float = (f[0] as Fighter).stats.stamina
	await steps(110)
	check(stam_after < FighterStats.STAMINA_CAP - 4.0, "stamina paid for the strike (%.1f / 255)" % stam_after)
	check(hits.size() == 1, "exactly one hit_landed (got %d)" % hits.size())
	if hits.size() >= 1:
		var info: Dictionary = hits[0]["info"]
		check(hits[0]["i"] == 0 and info["strike"] == "LJab" and info["zone"] == "head" and not info["blocked"], "attacker 0, LJab, head, unblocked")
		check(info["damage"] > 2.0 and info["damage"] < 6.0, "damage %.2f within LJab range" % info["damage"])
		check(info["strength"] == "light" and info.has("position") and info.has("counter"), "info keys: strength=%s counter=%s" % [info["strength"], str(info["counter"])])
		check(info["position"] is Vector3 and absf((info["position"] as Vector3).y - 1.5) < 0.35, "hit position near head height (%s)" % str(info["position"]))
	check((f[1] as Fighter).stats.head < p2_head, "defender head %.2f -> %.2f" % [p2_head, (f[1] as Fighter).stats.head])
	check(whiffs.is_empty(), "no whiff reported for a landed jab")
	var d: float = (f[0] as Fighter).global_position.distance_to((f[1] as Fighter).global_position)
	check(d > 0.45, "fighters not interpenetrating (%.2f m)" % d)

	print("== B. block: guard takes the hit, chip damage only")
	f = await duel(0.90)
	(f[1] as Fighter).external_input.block = true
	await steps(60)
	var guard0: float = (f[1] as Fighter).stats.guard
	var head0: float = (f[1] as Fighter).stats.head
	await throw(f[0], "LJab")
	await steps(100)
	check(hits.size() == 1 and hits[0]["info"]["blocked"], "hit registered as blocked (hits=%d)" % hits.size())
	check((f[1] as Fighter).stats.guard < guard0 - 10.0, "guard meter drained %.1f -> %.1f" % [guard0, (f[1] as Fighter).stats.guard])
	var chip: float = head0 - (f[1] as Fighter).stats.head
	check(chip >= 0.0 and chip < 1.0, "head chip damage only (%.2f)" % chip)
	if hits.size() == 1:
		check(hits[0]["info"]["damage"] < 1.0, "blocked info damage is the chip (%.2f)" % hits[0]["info"]["damage"])

	print("== C. slip: head leaves the glove path")
	var avoided := 0
	var landed_ctrl := 0
	for slip in [0, 1, -1]:
		f = await duel(0.90)
		(f[1] as Fighter).external_input.slip = slip
		await steps(30)
		await throw(f[0], "LJab")
		await steps(100)
		var head_hits := hits.filter(func(h): return h["info"]["zone"] == "head" and not h["info"]["blocked"]).size()
		print("       slip=%d -> head hits %d, whiffs %d, p2 state %s" % [slip, head_hits, whiffs.size(), (f[1] as Fighter).state_name])
		if slip == 0:
			landed_ctrl = head_hits
		elif head_hits == 0 and whiffs.size() >= 1:
			avoided += 1
	check(landed_ctrl == 1, "control (no slip) jab lands")
	check(avoided >= 1, "slip avoids the jab in %d of 2 directions (head genuinely moves)" % avoided)

	print("== D. duck beats a head hook")
	f = await duel(0.90)
	(f[1] as Fighter).external_input.duck = true
	await steps(40)
	await throw(f[0], "LHook")
	await steps(120)
	var hook_hits := hits.filter(func(h): return h["info"]["zone"] == "head").size()
	check(hook_hits == 0, "hook passes over a ducking head (head hits %d)" % hook_hits)

	print("== E. whiff outside range, body shot hits the torso, low kick hits a leg")
	f = await duel(1.9)
	await throw(f[0], "LJab")
	await steps(110)
	check(hits.is_empty() and whiffs.size() == 1 and whiffs[0]["strike"] == "LJab", "jab at 1.9 m whiffs (hits %d, whiffs %d)" % [hits.size(), whiffs.size()])
	f = await duel(0.90)
	await throw(f[0], "RBodyHook")
	await steps(130)
	check(hits.size() == 1 and hits[0]["info"]["zone"] == "body", "body hook lands on the body zone (hits %d)" % hits.size())
	f = await duel(0.95)
	await throw(f[0], "RLowKick")
	await steps(160)
	check(hits.size() == 1 and hits[0]["info"]["zone"] == "leg", "low kick lands on a leg (hits %d)" % hits.size())

	print("== F. knockdown -> count -> getup, other fighter frozen, KO ends the bout")
	f = await duel(1.4)
	var p2: Fighter = f[1]
	p2._do_knockdown("F")
	await steps(10)
	check(p2.state == Fighter.State.FALL and knockdowns == [1], "FALL state + knockdown signal for index 1")
	check((f[0] as Fighter).frozen, "opponent frozen during the knockdown sequence")
	var t_before := m.ms.time_left
	await steps(180)
	check(absf(m.ms.time_left - t_before) < 0.05, "round clock paused during the knockdown")
	# ragdoll: the fall lasts until the body is at rest (1.2 .. 4.5 s) instead of a fixed clip length
	var wait_count := 0
	while p2.state != Fighter.State.COUNT and wait_count < 120 * 6:
		await physics_frame
		wait_count += 1
	await steps(int(120.0 * 1.6))
	check(p2.state == Fighter.State.COUNT and counts.size() >= 1, "COUNT with count_tick (%d ticks)" % counts.size())
	var guard_t := 0
	while p2.state != Fighter.State.GETUP and guard_t < 120 * 14:
		await physics_frame
		guard_t += 1
	check(p2.state == Fighter.State.GETUP, "GETUP after the referee count to %d (state %s)" % [p2.getup_count, p2.state_name])
	await steps(260)
	check(p2.state == Fighter.State.IDLE and not (f[0] as Fighter).frozen, "back to IDLE, opponent released")
	check(counts.size() == p2.getup_count and counts[counts.size() - 1][1] == p2.getup_count, "referee count 1..%d" % p2.getup_count)
	f = await duel(1.4)
	(f[1] as Fighter)._do_ko("TKO", "F", "head")
	await steps(30)
	check((f[1] as Fighter).state == Fighter.State.DOWN, "KO -> DOWN state")
	await steps(120 * 5)
	check(results.size() == 1 and results[0]["winner"] == 0 and results[0]["method"] == "TKO", "match_ended winner 0 via TKO: %s" % str(results))

	print("== F2. power hook rocks, a weakened tired fighter goes down (natural rules path)")
	f = await duel(0.60)   # contact-only hits: the unaimed power hook needs this range to land square
	await throw(f[0], "RPHook")
	await steps(60)
	check(hits.size() == 1 and hits[0]["info"]["rocked"], "RPHook on a fresh head rocks: %s" % str(hits.map(func(h): return h["info"]["rocked"])))
	check((f[1] as Fighter).stats.rocked and (f[1] as Fighter).stats.stun_left > 2.2, "defender is rocked for %.2f s (> 2.2: the unaimed hook lands a little off centre, was > 2.5)" % (f[1] as Fighter).stats.stun_left)
	(f[1] as Fighter).external_input.strikes.append("LJab")
	await steps(30)
	(f[1] as Fighter).external_input.strikes.clear()
	check((f[1] as Fighter).state != Fighter.State.ATTACK, "rocked fighter cannot start a strike during the daze offence lock (state %s)" % (f[1] as Fighter).state_name)
	f = await duel(0.60)   # contact-only hits: the unaimed power hook needs this range to land square
	(f[1] as Fighter).stats.head = 20.0
	(f[1] as Fighter).stats.stamina = 40.0
	await throw(f[0], "RPHook")
	await steps(60)
	check(knockdowns == [1] and (f[1] as Fighter).state in [Fighter.State.FALL, Fighter.State.COUNT] and (f[1] as Fighter).stats.knockdowns == 1,
		"knockdown signal for index 1 (%s), state %s" % [str(knockdowns), (f[1] as Fighter).state_name])
	check(hits.size() == 1 and hits[0]["info"]["knockdown"], "hit info flags the knockdown")

	print("== F3. boxing rules refuse kicks; training mode gives a dummy and infinite stamina")
	await make_match({"mode": "exhibition", "rules": "boxing", "p1_controller": "dummy", "p2_controller": "dummy", "rounds": 1, "round_seconds": 60.0})
	check(not (m.get_fighters()[0] as Fighter).begin_attack("RRoundKick") and (m.get_fighters()[0] as Fighter).begin_attack("RJab"), "boxing: kick refused, jab accepted")
	await make_match({"mode": "training", "p1_controller": "human", "p2_controller": "human", "rounds": 1, "round_seconds": 0.0, "dummy_mode": "guarding"})
	var tf: Array = m.get_fighters()
	check((tf[1] as Fighter).controller == "dummy" and (tf[0] as Fighter).stats.infinite_stamina, "training: P2 is a dummy, stamina infinite")
	await steps(30)
	check(m.ms.timed == false and m.ms.time_left == 0.0, "training with round_seconds 0 has no timer")

	print("== F4. difficulty knob changes CPU behaviour (same seeds, easy vs hard vs a passive dummy)")
	var landed := {}
	for level in ["easy", "hard"]:
		await make_match({"mode": "exhibition", "p1_controller": "cpu", "p2_controller": "dummy", "rounds": 1, "round_seconds": 90.0, "cpu_difficulty": level})
		var t := 0
		# AI polish pass: CPUs now open each round with a ~13 s feeling-out period (few strikes), so the difficulty
		# comparison is made on the 10 s AFTER that opening (14 s settle, then count) instead of the first 10 s.
		while t < 120 * 14:
			await physics_frame
			t += 1
		hits.clear()
		whiffs.clear()
		t = 0
		while t < 120 * 30:   # 30 s (was 10): hard now throws bursts with rests, a 10 s window is mostly noise
			await physics_frame
			t += 1
		landed[level] = hits.filter(func(h): return h["i"] == 0).size() + whiffs.filter(func(w): return w["i"] == 0).size()
	print("       strikes thrown (landed + whiffed) against a passive dummy in 30 s (after the opening): %s" % str(landed))
	check(landed["hard"] > landed["easy"], "hard CPU throws more than easy CPU (%d vs %d)" % [landed["hard"], landed["easy"]])

	print("== F5. pausing the tree freezes fighters and the round clock")
	await make_match({"mode": "exhibition", "p1_controller": "cpu", "p2_controller": "cpu", "rounds": 1, "round_seconds": 60.0})
	await steps(240)
	paused_pos = [m.get_fighters()[0].global_position, m.get_fighters()[1].global_position]
	var clock0 := m.ms.time_left
	paused = true
	await steps(120)
	check(m.get_fighters()[0].global_position == paused_pos[0] and m.get_fighters()[1].global_position == paused_pos[1] and m.ms.time_left == clock0,
		"positions and clock unchanged after 1 s paused")
	paused = false
	await steps(120)
	check(m.ms.time_left < clock0 - 0.5, "clock runs again after resume (%.2f -> %.2f)" % [clock0, m.ms.time_left])

	print("== G. CPU vs CPU: stays in the ring, never interpenetrates, reaches a result")
	await make_match({"mode": "exhibition", "p1_controller": "cpu", "p2_controller": "cpu", "rounds": 2, "round_seconds": 30.0,   # was 10 s: the CPU opening (feeling-out) now takes the first ~13 s of a round
		"cpu_difficulty": "normal", "intermission": 0.5, "end_delay": 0.5})
	var cf: Array = m.get_fighters()
	var min_d := 9.0
	var max_ext := 0.0
	var frames := 0
	while results.is_empty() and frames < 120 * 80:   # (2 x 30 s rounds)
		await physics_frame
		frames += 1
		var a: Vector3 = cf[0].global_position
		var b: Vector3 = cf[1].global_position
		if cf[0].state != Fighter.State.FALL and cf[1].state != Fighter.State.FALL:
			min_d = minf(min_d, Vector2(a.x - b.x, a.z - b.z).length())
		max_ext = maxf(max_ext, maxf(maxf(absf(a.x), absf(a.z)), maxf(absf(b.x), absf(b.z))))
	print("       frames %d, hits %d (blocked %d), whiffs %d, knockdowns %d, min distance %.2f, max |coord| %.2f" % [
		frames, hits.size(), hits.filter(func(h): return h["info"]["blocked"]).size(), whiffs.size(), knockdowns.size(), min_d, max_ext])
	check(max_ext <= 3.25, "both fighters stay inside the ring (max |x|,|z| = %.2f <= 3.2 + 0.05)" % max_ext)
	check(min_d > 0.20, "never interpenetrate (min root distance %.2f > 0.20: the capsule floor is 0.24 now, the bodies are stopped by their own volumes)" % min_d)
	check(hits.size() >= 5, "CPUs landed hits through the physics path (%d)" % hits.size())
	check(hits.any(func(h): return h["info"]["blocked"]), "CPUs blocked at least once")
	check(results.size() == 1, "match_ended fired once: %s" % str(results))
	if results.size() == 1:
		check(results[0]["method"] in ["KO", "TKO", "Decision", "Draw"], "result method %s, winner %d" % [results[0]["method"], results[0]["winner"]])
	check(round_events == [1, 2] and timer_events.size() > 10, "round_started %s and timer_changed (%d events)" % [str(round_events), timer_events.size()])

	print("== H. names, corner colours, hair material")
	await make_match({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy", "p1_model": "viper", "p2_model": "anvil", "rounds": 1, "round_seconds": 60.0})
	var nf: Array = m.get_fighters()
	check((nf[0] as Fighter).display_name == "Viper" and (nf[1] as Fighter).display_name == "Anvil", "display names Viper / Anvil (%s / %s)" % [(nf[0] as Fighter).display_name, (nf[1] as Fighter).display_name])
	var gloves: Array = []
	for fi in nf:
		var col := Color.WHITE
		var hair_dark := false
		for mi in (fi as Fighter).model_root.find_children("*", "MeshInstance3D", true, false):
			for i in (mi as MeshInstance3D).mesh.get_surface_count():
				var mat := (mi as MeshInstance3D).get_active_material(i) as StandardMaterial3D
				if mat == null:
					continue
				if String(mat.resource_name).begins_with("Left_LOD"):
					col = mat.albedo_color
				if String(mat.resource_name).contains("Hair"):
					hair_dark = mat.albedo_color.v < 0.12
		gloves.append(col)
		check(hair_dark, "%s hair is dark" % (fi as Fighter).display_name)
	check(gloves[0] != gloves[1] and gloves[0].r > gloves[0].b and gloves[1].b > gloves[1].r, "P1 red / P2 blue gloves (%s / %s)" % [str(gloves[0]), str(gloves[1])])

	print("== I. round intro: fighters frozen, clock held, then the bout starts")
	await make_match({"mode": "exhibition", "p1_controller": "cpu", "p2_controller": "cpu", "rounds": 1, "round_seconds": 60.0, "intro_delay": 1.0})
	var itf: Array = m.get_fighters()
	var ip0: Vector3 = itf[0].global_position
	await steps(90)
	check(m.ms.time_left == 60.0 and itf[0].global_position.distance_to(ip0) < 0.01 and itf[0].state == Fighter.State.IDLE and itf[1].state == Fighter.State.IDLE,
		"nothing moves for the first 0.75 s (clock %.2f, state %s/%s)" % [m.ms.time_left, itf[0].state_name, itf[1].state_name])
	await steps(60)
	check(m.ms.time_left < 60.0, "clock runs after the intro (%.2f)" % m.ms.time_left)
	await make_match({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy", "rounds": 1, "round_seconds": 60.0, "intro_delay": 1.0})
	itf = m.get_fighters()
	itf[0].external_input = FighterInput.new()
	itf[0].external_input.strikes.append("LJab")
	await steps(30)
	itf[0].external_input.strikes.clear()
	check(itf[0].state != Fighter.State.ATTACK and itf[0].buffer.is_empty(), "scripted input is ignored during the intro too")

	print("== J. hard CPU vs hard CPU: clean hits land inside the first 20 s (no standing off at range)")
	await make_match({"mode": "exhibition", "p1_controller": "cpu", "p2_controller": "cpu", "rounds": 1, "round_seconds": 60.0, "cpu_difficulty": "hard"})
	var first_clean := -1.0
	var first_contact := -1.0
	var clean := 0
	var head_clean := 0
	var jf := 0
	while jf < 120 * 20:
		await physics_frame
		jf += 1
		if first_contact < 0.0 and (hits.size() > 0 or clash_times.size() > 0):
			first_contact = jf / 120.0
		if clean < hits.size():
			for h in hits.slice(clean):
				if not h["info"]["blocked"]:
					if first_clean < 0.0:
						first_clean = jf / 120.0
					if h["info"]["zone"] == "head":
						head_clean += 1
			clean = hits.size()
	var clean_n := hits.filter(func(h): return not h["info"]["blocked"]).size()
	var contacts := hits.size() + clash_times.size()
	print("       first contact at %.1f s, first clean hit at %.1f s; %d clean (%d head), %d blocked, %d glove clashes in 20 s" % [first_contact, first_clean, clean_n, head_clean, hits.size() - clean_n, clash_times.size()])
	# exchange: two jabs thrown together now glove-clash (no damage), so a clash replaces a would-be hit: engagement counts hits, blocks and clashes
	check(first_contact > 0.0 and first_contact < 10.0 and first_clean > 0.0 and contacts >= 6 and clean_n >= 3 and head_clean >= 2, "hard CPUs trade clean hits within 20 s (first contact %.1f s, %d clean, %d to the head, %d contacts)" % [first_contact, clean_n, head_clean, contacts])

	print("== K. strike timing follows the reference tempo (Tale of the Tape / Fight Night): quick jabs, hooks slower, kicks slowest")
	for tag in ["LJab", "RJab", "LHook", "RHook", "LUppercut", "RUppercut", "LRoundKick", "RFrontKick", "RLowKick"]:
		var sd := StrikeDB.get_strike(tag)
		print("       %-11s contact %.2f s, window %.2f-%.2f of %.2f" % [tag, sd["t_peak"], sd["w0"], sd["w1"], sd["action"]])
	var jab_s := StrikeDB.get_strike("LJab")
	check(jab_s["t_peak"] >= 0.13 and jab_s["t_peak"] <= 0.22 and jab_s["w0"] >= 0.07, "jab contact %.2f s (reference: out in ~0.1 s), window opens %.2f s" % [jab_s["t_peak"], jab_s["w0"]])
	check(StrikeDB.clip_time(jab_s, 0.04) > jab_s["clip_peak"] * 0.03, "the jab glove is moving within 0.04 s of the press (no dead start)")
	check(StrikeDB.get_strike("LHook")["t_peak"] > jab_s["t_peak"] and StrikeDB.get_strike("LRoundKick")["t_peak"] > StrikeDB.get_strike("RHook")["t_peak"], "hooks slower than jabs, kicks slowest")
	check(StrikeDB.clip_time(jab_s, 0.1) < jab_s["clip_peak"] * 0.5 and absf(StrikeDB.clip_time(jab_s, jab_s["t_peak"]) - jab_s["clip_peak"]) < 0.001, "clip reaches the fist peak exactly at the contact time, only a fraction by 0.1 s")

	print("== L. CPU reaction time: hard defends more of a scripted jab stream than easy")
	var defended := {}
	for level in ["easy", "hard"]:
		await make_match({"mode": "sparring", "p1_controller": "dummy", "p2_controller": "cpu", "rounds": 1, "round_seconds": 120.0, "cpu_difficulty": level})
		var lf: Array = m.get_fighters()
		lf[0].external_input = FighterInput.new()
		var thrown := 0
		var land0 := 0
		var lt := 0
		await steps(300)
		while thrown < 40 and lt < 120 * 100:
			# throw only when the CPU stands at jab range and is neutral, so every jab is a fair test
			var brain: CpuBrain = lf[1]._brain
			brain._assess = 5.0   # keep this CPU purely reactive: no offence, no random guard windows
			brain._cd = 5.0
			brain._alert_cd = 5.0
			if lf[0].state == Fighter.State.IDLE and lf[1].state == Fighter.State.IDLE:
				lf[1].global_position = lf[0].global_position + Vector3(0.85, 0, 0)
				lf[1].velocity = Vector3.ZERO
				await physics_frame
				lf[0].external_input.strikes.append("LJab")
				thrown += 1
				await physics_frame
				lf[0].external_input.strikes.clear()
				await steps(150)
			else:
				await physics_frame
			lt += 1
		var landed_n := hits.filter(func(h): return h["i"] == 0 and h["info"]["strike"] == "LJab" and not h["info"]["blocked"]).size()
		defended[level] = 1.0 - float(landed_n) / float(maxi(thrown, 1))
		print("       %s: %d jabs thrown, %d landed clean -> defended %.0f%%" % [level, thrown, landed_n, defended[level] * 100.0])
	check(defended["hard"] >= defended["easy"] + 0.15, "hard CPU defends clearly more jabs than easy (%.0f%% vs %.0f%%)" % [defended["hard"] * 100.0, defended["easy"] * 100.0])
	check(defended["easy"] < 0.3, "easy CPU rarely defends a jab (%.0f%%)" % [defended["easy"] * 100.0])
	check(defended["hard"] > 0.15, "hard CPU defends a share of jabs (%.0f%%)" % [defended["hard"] * 100.0])

	print("== M. knocked-down body: capsule stays on (collision exception with the foe), foe kept clear of the lying body, still on the floor after the get-up")
	f = await duel(0.9)
	p2 = f[1]
	var cs := p2.get_node("CollisionShape3D") as CollisionShape3D
	p2._do_knockdown("F")
	await steps(180)
	var pts: Array = p2.body_points()
	var dmin := 9.0
	var me := Vector3(f[0].global_position.x, 0, f[0].global_position.z)
	for i in range(1, pts.size()):
		var a: Vector3 = pts[0]
		var ab: Vector3 = pts[i] - a
		var q: Vector3 = a + ab * clampf((me - a).dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
		dmin = minf(dmin, me.distance_to(q))
	# ragdoll: the standing capsule is switched off while the body is simulated (it follows the pelvis on the floor)
	check(cs.disabled and p2._ragdoll.active and absf(p2.global_position.y) < 0.05, "downed fighter is a ragdoll, capsule off and following the body on the floor (y %.3f)" % p2.global_position.y)
	check(dmin >= Fighter.DOWNED_CLEARANCE - 0.03, "foe stands %.2f m from the lying body (>= %.2f)" % [dmin, Fighter.DOWNED_CLEARANCE])
	var wait := 0
	while p2.state != Fighter.State.IDLE and wait < 120 * 16:
		await physics_frame
		wait += 1
	check(p2.state == Fighter.State.IDLE and not cs.disabled and absf(p2.global_position.y) < 0.05, "back up after the get-up, capsule on, on the floor (state %s)" % p2.state_name)

	if failures == 0:
		print("PASS: fight simulation")
		quit(0)
	else:
		print("FAIL: %d check(s) failed" % failures)
		quit(1)
