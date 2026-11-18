extends SceneTree
## Windowed: slip / lean back / duck / slip-counter frames at 10 fps, 3/4 front camera -> _build/shots/slips/<model>_<scenario>_NN.png
## (compose with tools/make_slips_sheet.py).  godot --path . --script res://tests/capture_slips.gd -- model=meshy_viper
var main
var m
var f: Array
var cam: Camera3D
var model := "viper"
var side_view := false
const TICKS := 12   # 10 fps at 120 Hz


func _initialize() -> void:
	_run.call_deferred()


func fresh(gap := 0.95) -> void:
	if main != null:
		main.queue_free()
		await process_frame
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.start_match({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy", "p1_model": "anvil", "p2_model": model,
		"rules": "boxing", "rounds": 1, "round_seconds": 120.0, "arena": "ring", "intro_delay": 0.0})
	for i in 330:
		await physics_frame
	m = main.find_children("*", "Match", true, false)[0]
	f = m.get_fighters()
	f[0].external_input = FighterInput.new()
	f[1].external_input = FighterInput.new()
	f[0].global_position = Vector3(-gap * 0.5, 0, 0)
	f[1].global_position = Vector3(gap * 0.5, 0, 0)
	for i in 60:
		await physics_frame
	cam = Camera3D.new()
	cam.fov = 34.0
	root.add_child(cam)
	cam.current = true


func aim() -> void:
	var d: Fighter = f[1]
	var to_foe: Vector3 = f[0].global_position - d.global_position
	to_foe.y = 0
	to_foe = to_foe.normalized()
	var side: Vector3 = to_foe.cross(Vector3.UP)
	var focus := d.global_position + Vector3(0, 1.0, 0)
	cam.global_position = focus + (side * 3.4 if side_view else (to_foe * 0.55 + side * 0.8).normalized() * 3.6) + Vector3(0, 0.25, 0)
	cam.look_at(focus, Vector3.UP)


## events: {frame: Callable}; n frames; frame 0 is taken before any event
func film(name: String, n: int, events: Dictionary) -> void:
	for k in n:
		if events.has(k):
			events[k].call()
		for i in TICKS:
			await physics_frame
		aim()
		await process_frame
		await create_timer(0.03).timeout
		root.get_viewport().get_texture().get_image().save_png("res://_build/shots/slips/%s_%s%s_%02d.png" % [model, "side_" if side_view else "", name, k])
	print("saved ", name)


func _run() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("model="):
			model = a.substr(6)
		elif a == "side":
			side_view = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_build/shots/slips"))
	var d: Fighter
	var inp: FighterInput
	var foe_in: FighterInput
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("only="):
			only = a.substr(5)
	for nm in ["slip_l", "slip_r", "back", "duck", "slip_counter"]:
		if only != "" and only != nm:
			continue
		await fresh()
		d = f[1]
		inp = d.external_input
		foe_in = f[0].external_input
		match nm:
			"slip_l":
				await film(nm, 14, {1: func(): inp.slip = 1, 2: func(): foe_in.strikes.append("RJab"), 3: func(): foe_in.strikes.clear(), 8: func(): inp.slip = 0})
			"slip_r":
				await film(nm, 14, {1: func(): inp.slip = -1, 2: func(): foe_in.strikes.append("LJab"), 3: func(): foe_in.strikes.clear(), 8: func(): inp.slip = 0})
			"back":
				await film(nm, 14, {1: func(): inp.lean = Vector2(0, -1), 2: func(): foe_in.strikes.append("LJab"), 3: func(): foe_in.strikes.clear(), 8: func(): inp.lean = Vector2.ZERO})
			"duck":
				await film(nm, 14, {1: func(): inp.duck = true, 2: func(): foe_in.strikes.append("LHook"), 3: func(): foe_in.strikes.clear(), 8: func(): inp.duck = false})
			"slip_counter":
				await film(nm, 14, {1: func(): inp.slip = 1, 2: func(): foe_in.strikes.append("RJab"), 3: func(): foe_in.strikes.clear(),
					5: func(): inp.strikes.append("RHook"), 6: func(): inp.strikes.clear(), 10: func(): inp.slip = 0})
	quit(0)
