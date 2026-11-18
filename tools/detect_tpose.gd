extends SceneTree
## Headless T-pose detector. Runs many scripted and free fights; after every physics frame checks whether any fighter's final
## pose (logic skeleton, and the visible Meshy skeleton for Meshy models) is the rest / T pose, and logs path, state, model, duration.
## godot --headless --fixed-fps 120 --path . --script res://tools/detect_tpose.gd -- [cases=all|a,b] [models=meshy_anvil,viper] [seeds=2] [min=6]
const Probe := preload("res://tools/tpose_probe.gd")
const MESHY := ["meshy_viper", "meshy_anvil", "meshy_oak", "meshy_boxer1", "meshy_boxer2"]
const CLASSIC := ["viper", "anvil"]

var args := {}
var min_frames := 6
var hits: Array = []
var m: Match
var probes: Array = []
var cur_case := ""
var trace := false


func _initialize() -> void:
	_run.call_deferred()


func steps(n: int) -> void:
	for i in n:
		await physics_frame
		for p in probes:
			p.step()
			if trace and Engine.get_physics_frames() % 15 == 0:
				print("    %s P%d %s drv=%.1f meshy=%.1f rd=%s tree=%s" % [cur_case, p.fighter.player_index + 1, p.fighter.state_name, p.driver_deg, p.meshy_deg, str(p.fighter._ragdoll.active), str(p.fighter.anim.tree.active)])


func make_match(p1_model: String, p2_model: String, c1 := "dummy", c2 := "dummy", rounds := 1) -> Array:
	if m != null:
		root.remove_child(m)
		m.queue_free()
		await process_frame
	probes.clear()
	m = load("res://scenes/match.tscn").instantiate()
	m.setup({"intro_delay": 0.0, "mode": "exhibition", "rounds": rounds, "round_seconds": 600.0, "p1_controller": c1, "p2_controller": c2,
		"p1_model": p1_model, "p2_model": p2_model, "rules": "boxing", "end_delay": 1.0, "intermission": 1.0})
	root.add_child(m)
	await process_frame
	var f: Array = m.get_fighters()
	for x: Fighter in f:
		if x.controller == "dummy":
			x.external_input = FighterInput.new()
		x.stats.infinite_stamina = true
		probes.append(Probe.make(x))
	await steps(90)
	for p in probes:
		p.worst_run = 0   # ignore the spawn frames
		p.run_frames = 0
	return f


func report(label: String) -> void:
	for p in probes:
		if p.worst_run >= min_frames:
			var s := "T-POSE %s %s P%d: %d frames (%.2f s) %s" % [label, p.fighter.model, p.fighter.player_index + 1, p.worst_run, p.worst_run / 120.0, p.worst_info]
			print(s)
			hits.append(s)


func put_close(f: Array, gap := 0.85) -> void:
	f[0].global_position = Vector3(-gap * 0.5, 0, 0)
	f[1].global_position = Vector3(gap * 0.5, 0, 0)


func punch(f: Array, tag: String) -> void:
	f[0].external_input.strikes.append(tag)
	await physics_frame
	f[0].external_input.strikes.clear()


func wait_state(x: Fighter, st: Array, max_f := 900) -> bool:
	var n := 0
	while not (x.state in st) and n < max_f:
		await steps(1)
		n += 1
	return x.state in st


func ko_setup(v: Fighter, kd := 3) -> void:
	v.stats.head = 0.4
	v.stats.knockdowns = kd


## --- scripted cases (victim = P2, attacker = P1) -------------------------------------------------------------------------
func case_punch_ko(model: String, punch_tag := "RHook") -> void:
	var f: Array = await make_match("viper", model)
	await steps(30)
	put_close(f)
	await steps(30)
	ko_setup(f[1])
	await punch(f, punch_tag)
	await wait_state(f[1], [Fighter.State.DOWN], 900)
	await steps(600)


func case_tko(model: String) -> void:
	var f: Array = await make_match("viper", model)
	put_close(f)
	await steps(30)
	f[1]._do_ko("TKO", "F", "head")
	await steps(900)


func case_body_ko(model: String) -> void:
	var f: Array = await make_match("viper", model)
	put_close(f)
	await steps(30)
	f[1].stats.body_max = 0.0
	await punch(f, "RBodyHook")
	await wait_state(f[1], [Fighter.State.DOWN], 900)
	await steps(500)


func case_leg_ko(model: String) -> void:
	var f: Array = await make_match("viper", model)
	put_close(f)
	await steps(30)
	f[1].stats.lleg_max = 0.0
	f[1].stats.rleg_max = 0.0
	await punch(f, "LLowKick")
	await wait_state(f[1], [Fighter.State.DOWN], 900)
	await steps(500)


func case_flash_ko(model: String) -> void:
	var f: Array = await make_match("viper", model)
	put_close(f)
	await steps(30)
	f[1].stats.head = 14.0
	f[1].stats.knockdowns = 1
	f[1]._do_ko("KO", "L", "head")
	await steps(600)


## KO while the victim is already down (ragdoll running / count / get-up blend)
func case_ko_in(model: String, phase: String) -> void:
	var f: Array = await make_match("viper", model)
	put_close(f)
	await steps(30)
	f[1].stats.head = 30.0
	f[1]._do_knockdown("F")   # force a knockdown
	match phase:
		"fall":
			await steps(40)
		"count":
			await wait_state(f[1], [Fighter.State.COUNT], 900)
			await steps(30)
		"getup":
			f[1].getup_count = 4
			await wait_state(f[1], [Fighter.State.GETUP], 3000)
			await steps(30)
		"getup_end":
			f[1].getup_count = 4
			await wait_state(f[1], [Fighter.State.GETUP], 3000)
			await steps(int(f[1].anim.clip_length(f[1]._getup_clip) * 120.0) - 15)
	f[1]._do_ko("KO", "F", "head")
	await steps(900)


## KO while the victim is mid-lean / duck / punch
func case_ko_mid(model: String, what: String) -> void:
	var f: Array = await make_match("viper", model)
	put_close(f, 0.95)
	await steps(30)
	var v: Fighter = f[1]
	match what:
		"lean":
			v.external_input.slip = 1
		"leanback":
			v.external_input.lean = Vector2(0, -1)
		"duck":
			v.external_input.duck = true
		"punch":
			v.external_input.strikes.append("RHook")
		"block":
			v.external_input.block = true
	await steps(12)
	v.external_input.strikes.clear()
	ko_setup(v)
	await punch(f, "RHook")
	await wait_state(v, [Fighter.State.DOWN, Fighter.State.FALL], 600)
	v.external_input.clear()
	await steps(700)


## knockdown then the round / match is reset by the referee while the body is still down
func case_reset(model: String, phase: String) -> void:
	var f: Array = await make_match("viper", model, "dummy", "dummy", 3)
	put_close(f)
	await steps(30)
	f[1]._do_knockdown("F")
	match phase:
		"fall":
			await steps(30)
		"count":
			await wait_state(f[1], [Fighter.State.COUNT], 900)
		"getup":
			f[1].getup_count = 4
			await wait_state(f[1], [Fighter.State.GETUP], 3000)
			await steps(20)
		"ko":
			f[1]._do_ko("KO", "F", "head")
			await steps(200)
	for x: Fighter in f:
		x.reset_for_round(Vector3(-0.8 if x.player_index == 0 else 0.8, 0, 0), true)
	await steps(400)


## plain knockdown, the count, the get-up and then 6 s of standing again
func case_getup(model: String, who := 1) -> void:
	var f: Array = await make_match("viper", model if who == 1 else "viper", "dummy", "dummy")
	if who == 0:
		f = [f[1], f[0]]
	put_close(f)
	await steps(30)
	f[1].getup_count = 4
	f[1]._do_knockdown("F")
	await wait_state(f[1], [Fighter.State.GETUP], 3000)
	await wait_state(f[1], [Fighter.State.IDLE], 3000)
	await steps(720)


func case_victory(model: String) -> void:
	var f: Array = await make_match("viper", model)
	put_close(f)
	await steps(20)
	f[1]._do_ko("KO", "F", "head")
	await steps(300)
	f[0].start_victory()
	await steps(300)
	f[1].start_loss_pose()
	await steps(300)


## free fights: CPU vs CPU, human-slot P1 (no keys) vs CPU, dummy P1 that is farmed by a CPU
func case_fight(m1: String, m2: String, c1: String, c2: String, secs: float, seed_v: int) -> void:
	var f: Array = await make_match(m1, m2, c1, c2, 3)
	for x: Fighter in f:
		x.rng.seed = seed_v + x.player_index
		x.stats.infinite_stamina = false
	# soften the target so knockdowns / KOs happen quickly
	f[0].stats.head = 38.0
	f[1].stats.head = 90.0
	var n := int(secs * 120.0)
	var k := 0
	while k < n and f[0].state != Fighter.State.DOWN and f[1].state != Fighter.State.DOWN:
		await steps(120)
		k += 120
	await steps(900)


func _run() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	min_frames = int(args.get("min", "6"))
	trace = args.get("trace", "0") == "1"
	var models: Array = String(args.get("models", ",".join(MESHY + CLASSIC))).split(",")
	var seeds := int(args.get("seeds", "2"))
	var want: Array = String(args.get("cases", "all")).split(",")
	var t0 := Time.get_ticks_msec()
	for model: String in models:
		var cases := {
			"punch_ko": func() -> void: await case_punch_ko(model),
			"upper_ko": func() -> void: await case_punch_ko(model, "RUppercut"),
			"jab_ko": func() -> void: await case_punch_ko(model, "LJab"),
			"tko": func() -> void: await case_tko(model),
			"body_ko": func() -> void: await case_body_ko(model),
			"leg_ko": func() -> void: await case_leg_ko(model),
			"flash_ko": func() -> void: await case_flash_ko(model),
			"ko_in_fall": func() -> void: await case_ko_in(model, "fall"),
			"ko_in_count": func() -> void: await case_ko_in(model, "count"),
			"ko_in_getup": func() -> void: await case_ko_in(model, "getup"),
			"ko_in_getup_end": func() -> void: await case_ko_in(model, "getup_end"),
			"ko_lean": func() -> void: await case_ko_mid(model, "lean"),
			"ko_leanback": func() -> void: await case_ko_mid(model, "leanback"),
			"ko_duck": func() -> void: await case_ko_mid(model, "duck"),
			"ko_punch": func() -> void: await case_ko_mid(model, "punch"),
			"ko_block": func() -> void: await case_ko_mid(model, "block"),
			"reset_fall": func() -> void: await case_reset(model, "fall"),
			"reset_count": func() -> void: await case_reset(model, "count"),
			"reset_getup": func() -> void: await case_reset(model, "getup"),
			"reset_ko": func() -> void: await case_reset(model, "ko"),
			"getup": func() -> void: await case_getup(model),
			"victory": func() -> void: await case_victory(model),
		}
		for cname: String in cases:
			if want != ["all"] and not (cname in want):
				continue
			cur_case = "%s/%s" % [cname, model]
			await (cases[cname] as Callable).call()
			report(cur_case)
		if want == ["all"] or "fight" in want:
			var other: String = "meshy_oak" if model != "meshy_oak" else "viper"
			for s in seeds:
				for ctl in [["cpu", "cpu"], ["human", "cpu"], ["dummy", "cpu"]]:
					cur_case = "fight(%s,%s)/%s/%s/seed%d" % [ctl[0], ctl[1], model, other, s]
					await case_fight(model, other, ctl[0], ctl[1], 90.0, 1000 + s)
					report(cur_case)
					cur_case = "fight_rev(%s,%s)/%s/%s/seed%d" % [ctl[0], ctl[1], other, model, s]
					await case_fight(other, model, ctl[0], ctl[1], 90.0, 2000 + s)
					report(cur_case)
	print("detector done in %.0f s; %d T-pose occurrence(s)" % [(Time.get_ticks_msec() - t0) / 1000.0, hits.size()])
	for h in hits:
		print(h)
	quit(1 if hits.size() > 0 else 0)
