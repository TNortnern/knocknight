extends SceneTree
## Windowed capture of the liveliness layers (needs a display, not --headless):
##   godot --path . --script res://tools/capture_alive.gd -- mode=flinch|idle [dt=0.04] [n=12]
## flinch: calls fighter.flinch() on fighter 2 for jab (F 0.5), hook (L 1.0), uppercut (U 1.0) and body (F body 1.0).
##         Frames: _build/shots/alive_<name>_NN.png
## idle:   2 s of a standing fighter, a frame every 0.2 s: _build/shots/alive_idle_NN.png

var m: Match


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_build/shots"))
	DisplayServer.window_set_size(Vector2i(900, 700))
	m = load("res://scenes/match.tscn").instantiate()
	m.setup({"intro_delay": 0.0, "mode": "exhibition", "rounds": 1, "round_seconds": 600.0, "rules": "boxing",
		"p1_model": "viper", "p2_model": "anvil", "p1_controller": "dummy", "p2_controller": "dummy"})
	root.add_child(m)
	await process_frame
	var f: Array = m.get_fighters()
	var a: Fighter = f[0]
	var b: Fighter = f[1]
	a.global_position = Vector3(-0.55, 0, 0)
	b.global_position = Vector3(0.55, 0, 0)
	a.external_input = FighterInput.new()
	b.external_input = FighterInput.new()
	var cam: Camera3D = m.get_node("PlaceholderArena/Camera3D")
	cam.fov = 26.0
	cam.look_at_from_position(Vector3(0.0, 1.35, 4.2), Vector3(0.35, 1.2, 0))
	for i in 100:
		await physics_frame
	var dt: float = float(args.get("dt", "0.04"))
	var n: int = int(args.get("n", "12"))
	if args.get("mode", "flinch") == "idle":
		cam.fov = 30.0
		cam.look_at_from_position(Vector3(0.0, 1.3, 4.0), Vector3(0.0, 1.05, 0))
		for i in 12:
			await create_timer(0.2, true, false, true).timeout
			await _snap("alive_idle_%02d" % i)
		quit(0)
		return
	var cases := [["jab", "F", "head", 0.5], ["hook", "L", "head", 1.0], ["upper", "U", "head", 1.0], ["body", "F", "body", 1.0]]
	for c in cases:
		for i in 90:
			await physics_frame
		await _snap("alive_%s_pre" % c[0])
		b.flinch(a, {"dir": c[1]}, c[3], c[2])
		for i in n:
			await create_timer(dt, true, false, true).timeout
			await _snap("alive_%s_%02d" % [c[0], i])
	quit(0)


func _snap(name: String) -> void:
	await process_frame
	root.get_viewport().get_texture().get_image().save_png("res://_build/shots/%s.png" % name)
