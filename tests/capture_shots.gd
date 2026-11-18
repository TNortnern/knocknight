extends SceneTree
## Windowed screenshot capture: godot --path . --resolution 1600x900 -s res://tests/capture_shots.gd
## Writes PNGs to res://_build/shots/ (gitignored).

var main: Main
var out_dir := ""


func frames(n: int) -> void:
	for i in n:
		await process_frame


func shot(nm: String) -> void:
	await frames(3)
	var img := root.get_viewport().get_texture().get_image()
	img.save_png(out_dir + nm + ".png")
	print("saved ", nm)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	out_dir = ProjectSettings.globalize_path("res://_build/shots/")
	DirAccess.make_dir_recursive_absolute(out_dir)
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.force_stub = true
	main.results_delay = 0.3
	main.ko_results_delay = 0.3
	root.add_child(main)
	await frames(30)
	await shot("01_menu")
	(main.find_child("BtnSparring", true, false) as Button).grab_focus()
	await frames(40)
	await shot("01b_menu_sparring")
	main._on_mode_chosen("exhibition")
	await frames(10)
	await shot("02_setup_exhibition")
	main._on_mode_chosen("training")
	await frames(10)
	await shot("02b_setup_training")
	main._on_mode_chosen("exhibition")
	var cfg := (main.find_child("SetupScreen", true, false) as SetupScreen).build_config()
	main.start_match(cfg)
	main.current_match.auto_demo = true
	await frames(30)
	await shot("03_fight_intro")
	await create_timer(1.6).timeout
	main.current_match.fake_hit(0, "heavy", "head", false, 14.0)
	await create_timer(0.1).timeout
	await shot("04_fight_hit")
	main.current_match.fake_hit(1, "medium", "body", false, 8.0)
	main.current_match.fake_hit(0, "light", "head", true, 3.0)
	await create_timer(1.2).timeout
	await shot("05_fight_mid")
	main.current_match.knockdown.emit(1)
	main.current_match.count_tick.emit(1, 3)
	await create_timer(1.0).timeout
	await shot("06_knockdown")
	main.pause()
	await frames(10)
	await shot("07_pause")
	main.resume()
	main.current_match.fake_end(0, "KO")
	await create_timer(1.5).timeout
	await shot("08_ko")
	await create_timer(5.0).timeout
	await shot("09_results")
	cfg["arena"] = "octagon"
	main.start_match(cfg)
	main.current_match.auto_demo = true
	await create_timer(2.5).timeout
	await shot("10_octagon")
	quit()
