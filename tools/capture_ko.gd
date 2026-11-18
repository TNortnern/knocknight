extends SceneTree
## Windowed: delivers a REAL punch by scripted input so the ragdoll gets the true impulse, then saves frames every 0.08 s.
## <godot> --path . --script res://tools/capture_ko.gd -- punch=RHook tag=ko_hookR [gap=0.9] [mode=ko|kd|body|leg] [n=40] [getup=1] [model=anvil]
## Frames: _build/shots/<tag>_NN.png.  `python -I tools/make_sheet.py <tag> 8 1 0 0.08` makes a contact sheet.

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		if kv.size() == 2: args[kv[0]] = kv[1]
	var punch: String = args.get("punch", "RHook")
	var tag: String = args.get("tag", "ko_" + punch)
	var mode: String = args.get("mode", "ko")
	var gap: float = float(args.get("gap", "0.85"))
	var off: float = float(args.get("off", "0.0"))
	var n: int = int(args.get("n", "40"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_build/shots"))
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.start_match({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy",
		"p1_model": "viper", "p2_model": args.get("model", "anvil"), "rules": "boxing", "rounds": 3,
		"round_seconds": 180.0, "cpu_difficulty": "normal", "arena": "ring", "intro_delay": 0.0})
	for i in 60: await physics_frame
	var f: Array = main.current_match.get_fighters()
	var p1: Fighter = f[0]
	var p2: Fighter = f[1]
	p1.external_input = FighterInput.new()
	p2.external_input = FighterInput.new()
	p1.stats.infinite_stamina = true
	p2.stats.infinite_stamina = true
	p1.global_position = Vector3(-gap * 0.5, 0, off * 0.5)
	p2.global_position = Vector3(gap * 0.5, 0, -off * 0.5)
	for i in 60: await physics_frame
	match mode:
		"ko":
			p2.stats.head = 0.4
			p2.stats.knockdowns = 3
		"kd":
			p2.stats.head = 0.4
		"body":
			p2.stats.body_max = 0.0
		"leg":
			p2.stats.lleg_max = 0.0
	p1.external_input.strikes.append(punch)
	await physics_frame
	p1.external_input.strikes.clear()
	var guard := 0
	while not (p2.state in [Fighter.State.FALL, Fighter.State.DOWN]) and guard < 400:
		await physics_frame
		guard += 1
	if mode == "kd":
		p2.getup_count = 4   # footage: beat the count so the get-up shows
	var rdd = p2._ragdoll
	print("spec ", {"dir": rdd._last_start.get("dir"), "speed": rdd._last_start.get("speed"), "power": rdd._last_start.get("power"), "body": rdd._last_start.get("body"), "applied": rdd._last_start.get("applied")})
	print("pelvis v ", (rdd.bones["pelvis"] as PhysicalBone3D).linear_velocity, " head v ", (rdd.bones["head"] as PhysicalBone3D).linear_velocity, " tracked pelvis ", rdd._lin_vel.get("pelvis"))
	print("hit after ", guard, " frames; state ", p2.state_name, " last_hit speed ", p2._last_hit.get("ev", {}).get("speed", -1))
	for i in n:
		await create_timer(0.08, true, false, true).timeout
		if paused:
			main.resume()
		root.get_viewport().get_texture().get_image().save_png("res://_build/shots/%s_%02d.png" % [tag, i])
	if args.get("getup", "0") == "1":
		var k := 0
		while p2.state != Fighter.State.GETUP and k < 3000:
			await physics_frame
			k += 1
		for i in int(args.get("upn", "30")):
			await create_timer(0.08, true, false, true).timeout
			root.get_viewport().get_texture().get_image().save_png("res://_build/shots/%s_up_%02d.png" % [tag, i])
	print("p2 pos ", p2.global_position, " state ", p2.state_name)
	quit(0)
