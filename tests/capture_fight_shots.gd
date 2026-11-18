extends SceneTree
# Windowed screenshot capture of the fight core (needs a display, not --headless):
#   godot --path . --script res://tests/capture_fight_shots.gd
# Writes _build/shots/fight_*.png : idle face-off, hitbox overlay, jab landing, block, kick, knockdown, KO.

var m: Match
var hit_frames: Array = []
var frame_no := 0


func shot(name: String) -> void:
	await process_frame
	await process_frame
	var img := get_root().get_texture().get_image()
	img.save_png("res://_build/shots/fight_%s.png" % name)
	print("saved ", name)


func steps(n: int) -> void:
	for i in n:
		await physics_frame
		frame_no += 1


func make(gap: float, debug := false) -> Array:
	if m != null:
		get_root().remove_child(m)
		m.queue_free()
		await process_frame
	m = load("res://scenes/match.tscn").instantiate()
	m.debug_boxes = debug
	m.setup({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy", "rounds": 1, "round_seconds": 120.0})
	hit_frames.clear()
	m.hit_landed.connect(func(_i, _info): hit_frames.append(frame_no))
	get_root().add_child(m)
	await process_frame
	var f: Array = m.get_fighters()
	f[0].global_position = Vector3(-gap * 0.5, 0, 0)
	f[1].global_position = Vector3(gap * 0.5, 0, 0)
	f[0].external_input = FighterInput.new()
	f[1].external_input = FighterInput.new()
	var cam: Camera3D = m.get_node("PlaceholderArena/Camera3D")
	cam.fov = 38.0
	cam.look_at_from_position(Vector3(0.0, 1.45, 4.0), Vector3(0, 1.0, 0))
	await steps(100)
	return f


func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 720))
	var f := await make(2.3)
	await shot("idle")

	f = await make(0.95, true)
	await shot("hitboxes")

	f = await make(0.95)
	f[0].external_input.strikes.append("LJab")
	await steps(1)
	f[0].external_input.strikes.clear()
	var guard := 0
	while hit_frames.is_empty() and guard < 200:
		await steps(1)
		guard += 1
	await steps(3)
	await shot("jab_landing")
	await steps(14)
	await shot("jab_reaction")

	f = await make(0.95)
	f[1].external_input.block = true
	await steps(40)
	f[0].external_input.strikes.append("LJab")
	await steps(1)
	f[0].external_input.strikes.clear()
	guard = 0
	while hit_frames.is_empty() and guard < 200:
		await steps(1)
		guard += 1
	await steps(4)
	await shot("block")

	f = await make(1.2)
	f[0].external_input.strikes.append("RRoundKick")
	await steps(1)
	f[0].external_input.strikes.clear()
	await steps(36)
	await shot("kick")

	f = await make(1.2)
	f[1]._do_knockdown("F")
	await steps(50)
	await shot("knockdown_fall")
	await steps(180)
	await shot("knockdown_count")
	await steps(300)
	await shot("knockdown_getup")

	f = await make(1.2)
	f[1]._do_ko("KO", "F", "head")
	await steps(260)
	await shot("ko")
	quit()
