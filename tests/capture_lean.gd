extends SceneTree
## Windowed: lean sheets -> _build/shots/lean/<scenario>_<k>.png (compose with tools/make_lean_sheet.py)
## godot --path . --script res://tests/capture_lean.gd

var main
var m
var f: Array
var cam: Camera3D
var view := 0   # 0 = front 3/4 from the foe's side, 1 = side on


func _initialize() -> void:
	_run.call_deferred()


func fresh(gap := 0.95) -> void:
	if main != null:
		main.queue_free()
		await process_frame
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.start_match({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy", "p1_model": "anvil", "p2_model": "viper",
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


func aim_camera() -> void:
	var d: Fighter = f[1]
	var to_foe: Vector3 = (f[0].global_position - d.global_position)
	to_foe.y = 0
	to_foe = to_foe.normalized()
	var side: Vector3 = to_foe.cross(Vector3.UP)
	var focus := d.global_position + Vector3(0, 1.15, 0)
	var off: Vector3 = (to_foe * 0.35 + side * 0.9).normalized() * 3.4 if view == 0 else side * 2.8
	cam.global_position = focus + off + Vector3(0, 0.25, 0)
	cam.look_at(focus, Vector3.UP)
	cam.current = true


func shot(name: String, k: int) -> void:
	aim_camera()
	await process_frame
	await create_timer(0.03).timeout
	root.get_viewport().get_texture().get_image().save_png("res://_build/shots/lean/%s_%02d.png" % [name, k])


func run_frames(name: String, plan: Array) -> void:
	## plan: [[ticks_to_advance, callable_or_null], ...] a shot is taken after each step
	var k := 0
	for step in plan:
		if step[1] != null:
			step[1].call()
		for i in int(step[0]):
			await physics_frame
		await shot(name, k)
		k += 1
	print("saved ", name, " ", k)


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_build/shots/lean"))
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("only="):
			only = a.substr(5)
	var d: Fighter
	var inp: FighterInput
	var sc := {}
	# side leans both ways, lean back, lean forward bob, diagonal
	for nm in ["side_l", "side_r", "back", "fwd", "diag_back_l"]:
		if only != "" and only != nm:
			continue
		await fresh()
		d = f[1]
		inp = d.external_input
		var v: Vector2 = {"side_l": Vector2(1, 0), "side_r": Vector2(-1, 0), "back": Vector2(0, -1), "fwd": Vector2(0, 1), "diag_back_l": Vector2(0.7, -0.7)}[nm]
		await run_frames(nm, [[2, null], [8, func(): inp.lean = v], [10, null], [14, null], [30, null], [4, func(): inp.lean = Vector2.ZERO], [12, null], [14, null]])
	for nm in ["duck_fresh", "duck_rocked", "duck_gassed", "duck_both"]:
		if only != "" and only != nm:
			continue
		await fresh()
		d = f[1]
		inp = d.external_input
		if nm in ["duck_gassed", "duck_both"]:
			d.stats.stamina = d.stats.stamina_max * 0.04
		if nm in ["duck_rocked", "duck_both"]:
			d._begin_head_hurt(f[0], StrikeDB.get_strike("RHook"), 0.8, "F")
			for i in 40:
				await physics_frame
		await run_frames(nm, [[4, null], [6, func(): inp.duck = true], [14, null], [20, null], [40, null], [2, func(): inp.duck = false], [12, null]])
	if only == "" or only == "roll":
		await fresh()
		d = f[1]
		inp = d.external_input
		await run_frames("roll", [[2, null], [2, func(): inp.duck = true; inp.slip = 1; f[0].external_input.strikes.append("LHook")], [8, func(): f[0].external_input.strikes.clear()], [12, null], [16, null], [20, null], [26, func(): inp.duck = false; inp.slip = 0], [14, null]])
	if only == "" or only == "slip_counter":
		await fresh()
		d = f[1]
		inp = d.external_input
		await run_frames("slip_counter", [[2, func(): inp.slip = 1; f[0].external_input.strikes.append("RJab")], [4, func(): f[0].external_input.strikes.clear()], [10, null], [14, null], [30, null], [14, func(): inp.strikes.append("RHook")], [2, func(): inp.strikes.clear()], [8, null], [8, null], [10, null], [20, func(): inp.slip = 0], [20, null]])
	if only == "" or only == "hit_lean":
		await fresh()
		d = f[1]
		inp = d.external_input
		await run_frames("hit_lean", [[2, func(): inp.lean = Vector2(0.4, -0.2)], [40, func(): f[0].external_input.strikes.append("RHook")], [4, func(): f[0].external_input.strikes.clear()], [6, null], [6, null], [8, null], [12, null], [14, null]])
	if only == "" or only == "hit_back":
		await fresh()
		d = f[1]
		inp = d.external_input
		await run_frames("hit_back", [[2, func(): inp.lean = Vector2(0, -1)], [30, func(): f[0].external_input.strikes.append("LJab"); f[0].global_position = Vector3(-0.38, 0, 0)], [4, func(): f[0].external_input.strikes.clear()], [6, null], [6, null], [8, null], [12, null], [14, null]])
	quit(0)
