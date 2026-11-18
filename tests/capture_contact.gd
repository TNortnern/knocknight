extends SceneTree
## Windowed: a scripted body-contact sequence (Oak leans on Viper and walks him to the ropes, Viper shoves off) from main.tscn.
## Frames every 0.15 s into _build/film/contact_NNN.png.
## <godot> --path . --script res://tests/capture_contact.gd -- p1=meshy_oak p2=meshy_viper


func _initialize() -> void:
	_run.call_deferred()


func _walk(f: Fighter) -> FighterInput:
	var i := FighterInput.new()
	var d := f.dir_to_foe()
	i.move = Vector2(d.x, -d.z)
	return i


func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_build/film"))
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.start_match({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy", "intro_delay": 0.0,
		"p1_model": args.get("p1", "meshy_oak"), "p2_model": args.get("p2", "meshy_viper"), "rules": "boxing", "rounds": 1,
		"round_seconds": 600.0, "arena": "ring"})
	await process_frame
	var f: Array = main.current_match.get_fighters()
	var a: Fighter = f[0]
	var b: Fighter = f[1]
	a.external_input = FighterInput.new()
	b.external_input = FighterInput.new()
	a.global_position = Vector3(-0.6, 0, 0.5)
	b.global_position = Vector3(0.2, 0, 0.5)
	await create_timer(0.8, true, false, true).timeout
	var n := 0
	var t := 0.0
	var shoved := false
	while t < 12.0:
		a.external_input = _walk(a) if t < 7.5 else FighterInput.new()
		var bi := FighterInput.new()
		if t > 8.0 and not shoved:
			bi.shove = true
			shoved = true
		b.external_input = bi
		if t > 3.0 and t < 3.2:   # a short body shot in close
			a.external_input.strikes.append("RBodyHook") if false else null
		await create_timer(0.15, true, false, true).timeout
		t += 0.15
		root.get_viewport().get_texture().get_image().save_png("res://_build/film/contact_%03d.png" % n)
		n += 1
	quit(0)
