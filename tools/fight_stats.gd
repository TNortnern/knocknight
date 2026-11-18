extends SceneTree
## Headless diagnostic: CPU-vs-CPU bout (or P1 human-like button masher), prints fatigue / rock / knockdown / pacing stats.
## <godot> --headless --fixed-fps 120 --path . --script res://tools/fight_stats.gd -- diff=hard secs=180 rounds=3 seed=0 spam=0
## spam=1: P1 is a masher (throws a random jab/hook/uppercut every 0.15 s, walks in when out of range).
## seed=N shifts the CPU brain / fighter RNG seeds so several bouts can be averaged.

const CpuMetrics := preload("res://scripts/ai/cpu_metrics.gd")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		if kv.size() == 2: args[kv[0]] = kv[1]
	var secs := float(args.get("secs", "120"))
	var rounds := int(args.get("rounds", "1"))
	var seed_n := int(args.get("seed", "0"))
	var spam: bool = args.get("spam", "0") == "1"
	var m = load("res://scenes/match.tscn").instantiate()
	m.setup({"mode": "exhibition", "p1_controller": "dummy" if spam else "cpu", "p2_controller": "cpu",
		"p1_model": "viper", "p2_model": "anvil", "rules": "boxing", "rounds": rounds, "round_seconds": secs,
		"cpu_difficulty": args.get("diff", "normal"), "intro_delay": 0.0, "intermission": 1.0})
	var xch := {"trade_hits": 0, "trade_won": 0, "clashes": 0, "counters": 0, "open": 0, "punish": 0}
	m.clash.connect(func(_p): xch.clashes += 1)
	var st := {"hits": [0, 0], "rocked": [0, 0], "hurt_body": [0, 0], "kd": [0, 0], "strikes": [0, 0], "dmg": [0.0, 0.0], "whiffs": [0, 0]}
	var qual: Array = []        # quality of every unblocked hit
	var glances := [0]
	var rock_times: Array = []
	var rock_why: Array = []
	var kd_times: Array = []
	var clock := [0.0]
	var rnd := [1]
	m.hit_landed.connect(func(i, info):
		if not info.blocked:
			xch.counters += 1 if info.get("counter", false) else 0
			xch.open += 1 if info.get("open", false) else 0
			xch.punish += 1 if info.get("punish", false) else 0
		if info.get("trade", false):
			xch.trade_hits += 1
			if info.get("trade_won", false):
				xch.trade_won += 1
		if not info.blocked:
			qual.append(float(info.get("quality", 0.0)))
			if info.get("glance", false):
				glances[0] += 1
			st.hits[i] += 1
			st.dmg[i] += info.damage
			if info.get("rocked", false):   # what rocked them (strike, damage, counter) - for tuning
				rock_why.append("%s %.1f%s" % [info.strike, info.damage, " ctr" if info.get("counter", false) else ""]))
	m.whiffed.connect(func(i, _s): st.whiffs[i] += 1)
	m.fighter_state_changed.connect(func(i, s):
		if s == "rocked":
			st.rocked[i] += 1
			rock_times.append("R%d %.0fs P%d" % [rnd[0], clock[0], i + 1])
		if s == "hurt_body": st.hurt_body[i] += 1)
	m.knockdown.connect(func(i):
		st.kd[i] += 1
		kd_times.append("R%d %.0fs P%d" % [rnd[0], clock[0], i + 1]))
	m.round_started.connect(func(r): rnd[0] = r; clock[0] = 0.0)
	var ended := [false]
	var result := [{}]
	m.match_ended.connect(func(r): ended[0] = true; result[0] = r)
	root.add_child(m)
	await process_frame
	var f: Array = m.get_fighters()
	for i in 2:   # decorrelate bouts
		f[i].rng.seed = 1000 + i + seed_n * 31
		if f[i]._brain != null:
			f[i]._brain.rng.seed = 4242 + i * 77 + seed_n * 7919
	if args.get("flinch", "0") == "1":   # simulate the additive flinch layer (not merged yet on every branch)
		for i in 2:
			f[i]._hit_flinch = load("res://tools/flinch_stub.gd").new()
	var mash := RandomNumberGenerator.new()
	mash.seed = 99 + seed_n
	var met = CpuMetrics.new(f)
	var r1min := [1.0, 1.0]   # lowest stamina ratio in round 1
	var smin := [1.0, 1.0]
	var ssum := [0.0, 0.0]
	var below := [0, 0]      # ticks under 30 %
	var first_gassed := [-1.0, -1.0]
	var prev_serial := [f[0]._serial, f[1]._serial]
	var ticks := 0
	var total_t := 0.0
	var fight_ticks := 0
	var max_t := (secs + 12.0) * rounds + 10.0
	while total_t < max_t and not ended[0]:
		if spam:
			var inp := FighterInput.new()
			inp.move = Vector2(0, 1) if f[0].gap_to_foe() > 0.9 else Vector2.ZERO
			if ticks % 18 == 0:
				inp.strikes.append(["LJab", "RJab", "LHook", "RHook", "RUppercut"][mash.randi() % 5])
			f[0].external_input = inp
		await physics_frame
		ticks += 1
		total_t += 1.0 / 120.0
		clock[0] += 1.0 / 120.0
		if m.ms.phase != MatchState.Phase.FIGHT:
			continue
		fight_ticks += 1
		if not (f[0].is_acute_down() or f[1].is_acute_down()):
			met.sample(1.0 / 120.0)
		if args.get("trace", "0") == "1" and fight_ticks % int(float(args.get("every", "10")) * 120.0) == 0:
			print("  t=%3.0f R%d  P1 head %.0f/%.0f body %.0f/%.0f stam %.0f%%   P2 head %.0f/%.0f body %.0f/%.0f stam %.0f%%" % [clock[0], rnd[0],
				f[0].stats.head, f[0].stats.head_max, f[0].stats.body, f[0].stats.body_max, f[0].stats.stamina_ratio() * 100.0,
				f[1].stats.head, f[1].stats.head_max, f[1].stats.body, f[1].stats.body_max, f[1].stats.stamina_ratio() * 100.0])
		for i in 2:
			var r: float = f[i].stamina / maxf(f[i].stamina_max, 1.0)
			smin[i] = minf(smin[i], f[i].stamina / FighterStats.STAMINA_CAP)
			if rnd[0] == 1:
				r1min[i] = minf(r1min[i], f[i].stamina / FighterStats.STAMINA_CAP)
			ssum[i] += f[i].stamina / FighterStats.STAMINA_CAP
			if r < 0.30:
				below[i] += 1
				if first_gassed[i] < 0.0:
					first_gassed[i] = clock[0]
			if f[i]._serial != prev_serial[i]:
				st.strikes[i] += f[i]._serial - prev_serial[i]   # counts back-to-back strikes (a new attack id per strike)
				prev_serial[i] = f[i]._serial
	var ft := fight_ticks / 120.0
	print("--- seed %d  diff %s  rounds %d x %.0fs  spam %s" % [seed_n, args.get("diff", "normal"), rounds, secs, str(spam)])
	print("result %s   fight seconds %.0f (round reached %d)" % [str(result[0].get("method", "?")) + " winner " + str(result[0].get("winner", "?")), ft, rnd[0]])
	for i in 2:
		print("P%d strikes %d (%.0f/min)  whiffs %d  clean hits %d  dmg %.0f  rocked %d  body-hurt %d  knockdowns %d  stamina min %.0f%% avg %.0f%%  time<30%% %.1fs  first<30%% at %.0fs" % [
			i + 1, st.strikes[i], st.strikes[i] / maxf(ft, 1.0) * 60.0, st.whiffs[i], st.hits[i], st.dmg[i], st.rocked[i], st.hurt_body[i], st.kd[i],
			smin[i] * 100.0, ssum[i] / maxf(fight_ticks, 1) * 100.0, below[i] / 120.0, first_gassed[i]])
	for i in 2:
		print(met.report(i), "   R1 stamina min %.0f%%" % (r1min[i] * 100.0))
	var qsum := 0.0
	for q in qual:
		qsum += q
	print("hit quality avg %.2f over %d unblocked hits, glances %d" % [qsum / maxf(qual.size(), 1), qual.size(), glances[0]])
	print("exchange: trade hits %d (winner's %d)  clashes %d  counters %d (whiff-open %d, uppercut punish %d)" % [xch.trade_hits, xch.trade_won, xch.clashes, xch.counters, xch.open, xch.punish])
	for i in 2:
		print("P%d as defender  guard outcomes %s" % [i + 1, str(f[i].guard_log)])
	print("rocked by: ", ", ".join(rock_why))
	print("rocks: ", ", ".join(rock_times), "   knockdowns: ", ", ".join(kd_times))
	quit(0)
