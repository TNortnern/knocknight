extends SceneTree
# CPU pacing + footwork (AI polish pass): hard viper (out-boxer) vs hard anvil (pressure), simulated 3-minute rounds.
# Checks strikes/min, round-1 stamina, distance walked, ring coverage, circling share, combo-then-reset bursts, the
# feeling-out opening and that the two styles fight differently.
# godot --headless --fixed-fps 120 --path . --script res://tests/test_cpu_pacing.gd
# Prints PASS/FAIL and exits 0 / 1.

const CpuMetrics := preload("res://scripts/ai/cpu_metrics.gd")
const SEEDS := [0, 1, 2, 3]
const MIN_VALID_SECS := 90.0      ## a bout that ends sooner (early KO) does not count for the rate checks

var failures := 0


func check(ok: bool, msg: String) -> void:
	if ok:
		print("  ok   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1


func _initialize() -> void:
	_run.call_deferred()


## One round-1 bout. Returns metrics + the round-1 stamina minima + opening numbers.
func bout(seed_n: int) -> Dictionary:
	var m = load("res://scenes/match.tscn").instantiate()
	m.setup({"mode": "exhibition", "p1_controller": "cpu", "p2_controller": "cpu", "p1_model": "viper", "p2_model": "anvil",
		"rules": "boxing", "rounds": 1, "round_seconds": 180.0, "cpu_difficulty": "hard", "intro_delay": 0.0, "intermission": 1.0})
	var clock := [0.0]
	var first_rock := [999.0]
	m.fighter_state_changed.connect(func(_i, s):
		if s == "rocked":
			first_rock[0] = minf(first_rock[0], clock[0]))
	var ended := [false]
	m.match_ended.connect(func(_r): ended[0] = true)
	root.add_child(m)
	await process_frame
	var f: Array = m.get_fighters()
	for i in 2:   # decorrelate bouts (same seeding as tools/fight_stats.gd)
		f[i].rng.seed = 1000 + i + seed_n * 31
		f[i]._brain.rng.seed = 4242 + i * 77 + seed_n * 7919
	var met = CpuMetrics.new(f)
	var smin := [1.0, 1.0]
	var opening := [-1, -1]   # strikes thrown in the first 12 s
	var guard := 0
	while not ended[0] and guard < 120 * 200:
		await physics_frame
		guard += 1
		if m.ms.phase != MatchState.Phase.FIGHT:
			continue
		if f[0].is_acute_down() or f[1].is_acute_down():
			continue
		clock[0] += 1.0 / 120.0
		met.sample(1.0 / 120.0)
		for i in 2:
			smin[i] = minf(smin[i], f[i].stamina / maxf(f[i].stamina_max, 1.0))
		if opening[0] < 0 and met.t >= 12.0:
			opening = [met.strikes[0], met.strikes[1]]
	met.finish()
	var out := {"met": met, "smin": smin, "opening": opening, "first_rock": first_rock[0], "secs": met.t}
	root.remove_child(m)
	m.queue_free()
	await process_frame
	return out


func _finished() -> void:
	print("PASS" if failures == 0 else "FAIL (%d)" % failures)
	quit(0 if failures == 0 else 1)


func _run() -> void:
	var bouts: Array = []
	for s in SEEDS:
		var b: Dictionary = await bout(s)
		bouts.append(b)
		print("-- seed %d: %.0f s fought" % [s, b["secs"]])
		for i in 2:
			print("   ", b["met"].report(i), "  stamina min %.0f%%" % (b["smin"][i] * 100.0))
	var valid: Array = bouts.filter(func(b): return b["secs"] >= MIN_VALID_SECS)
	check(valid.size() >= 3, "at least 3 of %d bouts lasted %.0f s+ (%d did)" % [SEEDS.size(), MIN_VALID_SECS, valid.size()])

	print("== pacing")
	var rate_ok := true
	var stam_ok := 0
	var stam_n := 0
	var stam_floor := true
	var rates: Array = []
	var rmin := 999.0
	var rmax := 0.0
	for b in valid:
		for i in 2:
			var r: float = b["met"].per_min(i)
			rmin = minf(rmin, r)
			rmax = maxf(rmax, r)
			rates.append(r)
			if r < 18.0 or r > 40.0:   # a single bout can run hot when one CPU swarms a rocked foe (rests are cancelled)
				rate_ok = false
			stam_n += 1
			if b["smin"][i] >= 0.35:
				stam_ok += 1
			if b["smin"][i] < 0.12:
				stam_floor = false
	rates.sort()
	var med: float = (rates[rates.size() / 2 - 1] + rates[rates.size() / 2]) * 0.5 if rates.size() >= 2 else 0.0
	# the owner's tempo reference (Tale of the Tape / Fight Night) keeps the fighters busier than the old 18-28 band
	check(rate_ok and med >= 24.0 and med <= 34.0, "CPU strikes/min: median %.1f in 24-34, every bout in 18-40 (range %.1f-%.1f)" % [med, rmin, rmax])
	check(stam_ok >= int(ceil(stam_n * 0.75)), "round-1 stamina minimum is at least 35%% in >= 75%% of CPU-bouts (%d / %d)" % [stam_ok, stam_n])
	check(stam_floor, "nobody is emptied (< 12%) in round 1 (a sustained exchange may still gas someone)")

	print("== feeling-out opening")
	var op_sum := 0
	var early_rock := false
	for b in valid:
		op_sum += int(b["opening"][0]) + int(b["opening"][1])
		if b["first_rock"] < 8.0:
			early_rock = true
	var op_avg := float(op_sum) / valid.size()
	check(op_avg <= 6.0, "first 12 s: both fighters together average %.1f strikes (full pace would be ~9-10)" % op_avg)
	check(not early_rock, "nobody is rocked inside the first 8 s")

	print("== footwork")
	var walked := true
	var spread := true
	var circling := true
	var combos := true
	var combo_rate := [0.0, 0.0]   # per fighter slot, combos per 3 min summed over bouts
	for b in valid:
		for i in 2:
			var met = b["met"]
			if met.dist[i] < 60.0 * met.t / 180.0:
				walked = false
			var sp: Vector2 = met.span(i)
			if maxf(sp.x, sp.y) < 2.5:
				spread = false
			if met.lateral_share(i) <= 0.25:
				circling = false
			# One bout can land right on the line (a pressure fighter that stays in after a combo is in style), so
			# the target is the average over the bouts, with a per-bout floor of 3.
			combo_rate[i] += met.combos[i] * 180.0 / maxf(met.t, 1.0)
			if met.combos[i] < 3.0 * met.t / 180.0:
				combos = false
	check(walked, "each CPU walks >= 60 m per 3 min")
	check(spread, "each CPU's positions span >= 2.5 m on some axis (uses the ring)")
	check(circling, "lateral (circling) movement is > 25% of the distance walked")
	for i in 2:
		if combo_rate[i] / valid.size() < 5.0:
			combos = false
	check(combos, "each CPU averages >= 5 bursts of 2-4 strikes followed by a reset (>= 0.5 m of footwork) per 3 min, >= 3 in every bout (avg %.1f / %.1f)" % [combo_rate[0] / valid.size(), combo_rate[1] / valid.size()])

	print("== styles")
	var adv_gap := 0.0
	for b in valid:
		adv_gap += b["met"].advance_share(1) - b["met"].advance_share(0)
	adv_gap /= valid.size()
	check(adv_gap >= 0.2, "pressure fighter (anvil) walks forward %.0f points more of the time than the out-boxer (viper)" % (adv_gap * 100.0))
	var cut_circ := 0.0
	for b in valid:
		cut_circ += b["met"].dist[0] - b["met"].dist[1]
	check(cut_circ > 0.0, "the out-boxer covers more ground than the pressure fighter (%.0f m over %d bouts)" % [cut_circ, valid.size()])
	_finished()
