extends SceneTree
## Windowed: CPU-vs-CPU fight, 16 frames every 0.4 s -> _build/shots/guard_XX.png.
## With --variants: two idle dummies 1.9 m apart on a side camera, one frame per guard variant -> guard_var_*.png.

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
	await create_timer(3.0).timeout
	for i in 16:
		await create_timer(0.4).timeout
		root.get_viewport().get_texture().get_image().save_png("res://_build/shots/guard_%02d.png" % i)
	print("saved fight frames")
	quit(0)
