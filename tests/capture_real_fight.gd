extends SceneTree
## Windowed: runs main.tscn into a real CPU-vs-CPU exhibition and saves shots to _build/shots/real_*.png.

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_build/shots"))
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.start_match({"mode": "exhibition", "p1_controller": "cpu", "p2_controller": "cpu",
		"p1_model": "viper", "p2_model": "anvil", "rules": "kickboxing", "rounds": 3,
		"round_seconds": 180.0, "cpu_difficulty": "hard", "arena": "ring"})
	for i in 24:
		await create_timer(2.0).timeout
		root.get_viewport().get_texture().get_image().save_png("res://_build/shots/real_%02d.png" % i)
		print("saved real_%02d" % i)
	quit(0)
