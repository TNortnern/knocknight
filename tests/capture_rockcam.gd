extends SceneTree
## Windowed: real main.tscn, P1 lands a power hook on P2 (rock meter pre-filled); saves ~30 full frames along the rock camera
## sequence to _build/shots/rockcam_NN.png (time = rock age as seen by the camera model).
## godot --path . --script res://tests/capture_rockcam.gd

const TIMES := [0.0, 0.017, 0.033, 0.05, 0.067, 0.083, 0.1, 0.113, 0.15, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 2.0, 2.2, 2.4, 2.7]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_build/shots"))
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.start_match({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy",
		"p1_model": "viper", "p2_model": "anvil", "rules": "kickboxing", "rounds": 1,
		"round_seconds": 180.0, "arena": "ring", "intro_delay": 0.0})
	var f: Array = main.current_match.get_fighters()
	f[0].external_input = FighterInput.new()
	f[1].external_input = FighterInput.new()
	f[0].global_position = Vector3(-0.45, 0, 0)
	f[1].global_position = Vector3(0.45, 0, 0)
	for i in 300:
		await physics_frame
	var t: Fighter = f[1]
	t.stats.rock_meter = 40.0
	f[0].external_input.strikes.append("RHook")
	await physics_frame
	f[0].external_input.strikes.clear()
	var cam: FightCamera = main.current_camera
	var guard := 0
	while cam.impact.impulses.is_empty() and guard < 900:
		await physics_frame
		guard += 1
	print("rock started after %d ticks, state %s" % [guard, t.state_name])
	Engine.time_scale = 0.08
	var n := 0
	var g2 := 0
	while n < TIMES.size() and g2 < 20000:
		var age := 99.0
		var best: Dictionary = {}
		for s in cam.impact.impulses:
			if s["camera"]["kind"] == "rock":
				age = s["age"]
		if age >= TIMES[n]:
			await RenderingServer.frame_post_draw
			root.get_viewport().get_texture().get_image().save_png("res://_build/shots/rockcam_%02d.png" % n)
			print("  rockcam_%02d age=%.3f scale=%.3f roll=%.2f blur=%.2f fov=%.1f" % [n, age, cam.impact.image_scale, cam.impact.roll_deg, cam.impact.blur, cam.fov])
			n += 1
		else:
			await process_frame
			g2 += 1
	Engine.time_scale = 1.0
	quit(0)
