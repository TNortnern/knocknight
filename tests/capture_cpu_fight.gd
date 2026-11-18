extends SceneTree
# Windowed: CPU vs CPU, a screenshot every 1.5 s of play -> _build/shots/cpu_NN.png (also slip / duck / walk poses)
#   godot --path . --fixed-fps 120 --script res://tests/capture_cpu_fight.gd


func shot(name: String) -> void:
	await process_frame
	await process_frame
	get_root().get_texture().get_image().save_png("res://_build/shots/%s.png" % name)
	print("saved ", name)


func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 720))
	var m: Match = load("res://scenes/match.tscn").instantiate()
	m.setup({"mode": "exhibition", "p1_controller": "cpu", "p2_controller": "cpu", "rounds": 1, "round_seconds": 60.0, "cpu_difficulty": "hard"})
	get_root().add_child(m)
	await process_frame
	var cam: Camera3D = m.get_node("PlaceholderArena/Camera3D")
	cam.fov = 40.0
	for i in 8:
		for k in 180:
			await physics_frame
		var f: Array = m.get_fighters()
		var mid: Vector3 = (f[0].global_position + f[1].global_position) * 0.5
		cam.look_at_from_position(mid + Vector3(0, 0.6, 3.6), mid + Vector3(0, 1.0, 0))
		await shot("cpu_%02d" % i)
	quit()
