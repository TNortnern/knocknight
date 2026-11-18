extends SceneTree
## Windowed: films a fighter pinned on the ropes (or in a corner) while the foe presses and spams punches, from a fixed side camera.
## <godot> --path . --script res://tools/film_pinned.gd -- case=rope secs=12 every=0.1 tag=p
## case=rope (back to +x rope, camera on +z side) | corner (back in the -x,-z corner, camera on +x,-z side, looking along the diagonal)
## Frames land in _build/film/<tag>_NNN.png.
func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		if kv.size() == 2: args[kv[0]] = kv[1]
	var secs := float(args.get("secs", "12"))
	var every := float(args.get("every", "0.1"))
	var tag: String = args.get("tag", "p")
	var corner: bool = args.get("case", "rope") == "corner"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_build/film"))
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.start_match({"intro_delay": 0.0, "mode": "exhibition", "rounds": 1, "round_seconds": 600.0, "rules": "boxing",
		"p1_model": "viper", "p2_model": "anvil", "p1_controller": "dummy", "p2_controller": "dummy", "arena": "ring"})
	await process_frame
	var f: Array = main.current_match.get_fighters()
	for i in 90:
		await physics_frame
	var face: Vector3 = Vector3(1, 0, 1).normalized() if corner else Vector3(-1, 0, 0)
	var pos1: Vector3 = Vector3(-2.85, 0, -2.85) if corner else Vector3(2.85, 0, 0.3)
	f[0].global_position = pos1
	f[1].global_position = pos1 + (-pos1.normalized() if corner else face) * 1.2
	var cam := Camera3D.new()
	root.add_child(cam)
	var mid: Vector3 = pos1 + (f[1].global_position - pos1) * 0.5 + Vector3(0, 1.1, 0)
	cam.fov = 38
	if corner:
		cam.global_position = mid + Vector3(3.6, 0.9, -3.6) * 0.8
	else:
		cam.global_position = mid + Vector3(-0.2, 0.3, 3.6)
	cam.look_at(mid)
	cam.current = true
	f[0].stats.infinite_stamina = true
	f[1].stats.infinite_stamina = true
	var rnd := RandomNumberGenerator.new()
	rnd.seed = 7
	var strikes := ["RJab", "LHook", "RHook", "RUppercut", "LJab", "LUppercut"]
	var into: Vector3 = -pos1.normalized() if corner else face
	var n := int(secs / every)
	var per := int(every * 120.0)
	for k in n:
		for j in per:
			var inp := FighterInput.new()
			inp.move = Vector2(-into.x, into.z)
			f[0].stats.head = 100.0
			f[0].stats.body = 100.0
			f[0].stats.rock_meter = 0.0
			f[0].stats.rocked = false
			f[0].external_input = inp
			var inp2 := FighterInput.new()
			inp2.move = Vector2(into.x, -into.z)
			if (k * per + j) % 22 == 0:
				inp2.strikes.append(strikes[rnd.randi() % strikes.size()])
			f[1].external_input = inp2
			await physics_frame
		root.get_viewport().get_texture().get_image().save_png("res://_build/film/%s_%03d.png" % [tag, k])
	quit(0)
