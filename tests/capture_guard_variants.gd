extends SceneTree
## Windowed: two idle dummies on a side camera; one frame per guard variant per fighter -> _build/shots/guard_var_*.png

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_build/shots"))
	var m = load("res://scenes/match.tscn").instantiate()
	m.setup({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy", "rounds": 1, "round_seconds": 120.0, "intro_delay": 0.0, "p1_model": "viper", "p2_model": "anvil"})
	root.add_child(m)
	await process_frame
	var f: Array = m.get_fighters()
	f[0].global_position = Vector3(-0.95, 0, 0)
	f[1].global_position = Vector3(0.95, 0, 0)
	f[0].external_input = FighterInput.new()
	f[1].external_input = FighterInput.new()
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.current = true
	cam.position = Vector3(0.0, 1.35, -3.0)
	cam.look_at(Vector3(0, 1.25, 0))
	cam.fov = 38
	for i in 100: await physics_frame
	for v in GuardStyle.VARIANTS:
		for fx in f:
			fx.guard_style._enter(v, 100.0)
		for i in 100: await physics_frame
		await process_frame
		root.get_viewport().get_texture().get_image().save_png("res://_build/shots/guard_var_%s.png" % v)
	quit(0)
