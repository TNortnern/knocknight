extends SceneTree
## Windowed: stages block outcomes and saves a frame every 0.05 s -> _build/shots/gm_<name>_NN.png
##   godot --path . --script res://tests/capture_guard_moves.gd
const ExchangeScript := preload("res://scripts/combat/exchange.gd")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_build/shots"))
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	var scen := {
		"parry": ["anvil", "LJab", "press"],
		"pierce": ["viper", "RHook~wide", "held"],
		"uppercut": ["anvil", "RUppercut", "held"],
		"knock": ["anvil", "LJab", "held"],
	}
	for name in scen:
		var sc: Array = scen[name]
		main.start_match({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy", "p1_model": "viper", "p2_model": sc[0],
			"rules": "boxing", "rounds": 1, "round_seconds": 300.0, "arena": "ring", "intro_delay": 0.0})
		for i in 150:
			await physics_frame
		var m = main.find_children("*", "Match", true, false)[0]
		var f: Array = m.get_fighters()
		for fx in f:
			fx.external_input = FighterInput.new()
			fx.stats.infinite_stamina = true
		f[0].global_position = Vector3(-0.4, 0, 0)
		f[1].global_position = Vector3(0.4, 0, 0)
		if sc[2] == "held":
			f[1].external_input.block = true
		for i in 100:
			await physics_frame
		f[0].begin_attack(sc[1])
		var pressed: bool = sc[2] == "held"
		for k in 14:
			for i in 6:
				await physics_frame
				if not pressed and f[0].state == Fighter.State.ATTACK and not f[0].atk.is_empty() and ExchangeScript.time_to_contact(f[0].atk) <= 0.075:
					f[1].external_input.block = true
					pressed = true
			await RenderingServer.frame_post_draw
			root.get_viewport().get_texture().get_image().save_png("res://_build/shots/gm_%s_%02d.png" % [name, k])
		print(name, " ", f[1].last_assess.get("kind", "?"))
		f[1].external_input.block = false
	quit(0)
