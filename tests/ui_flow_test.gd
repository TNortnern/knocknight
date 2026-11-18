extends SceneTree
## Headless UI flow test: menu -> setup -> match (stub unless match.tscn exists) -> results -> menu,
## plus arena collider/geometry checks. Run:
##   godot --headless --path . -s res://tests/ui_flow_test.gd
## Prints PASS/FAIL lines, exits non-zero on any failure.

var failures := 0
var checks := 0
var main: Main


func check(cond: bool, label: String, detail := "") -> void:
	checks += 1
	if cond:
		print("PASS  ", label)
	else:
		failures += 1
		print("FAIL  ", label, ("  [" + detail + "]") if detail != "" else "")


func frames(n: int) -> void:
	for i in n:
		await process_frame


func press(node_name: String) -> void:
	var b := main.find_child(node_name, true, false) as Button
	check(b != null and b.is_visible_in_tree(), "button %s visible" % node_name)
	if b:
		b.pressed.emit()
	await frames(3)


func ray(from: Vector3, to: Vector3) -> Dictionary:
	var space := main.get_viewport().world_3d.direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to, 1)
	return space.intersect_ray(q)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var packed := load("res://scenes/main.tscn") as PackedScene
	main = packed.instantiate() as Main
	main.force_stub = true
	main.results_delay = 0.2
	main.ko_results_delay = 0.2
	root.add_child(main)
	await frames(3)

	check(main.get_state_name() == "MENU", "boots into MENU", main.get_state_name())
	await press("BtnExhibition")
	check(main.get_state_name() == "SETUP", "exhibition opens SETUP", main.get_state_name())
	var setup := main.find_child("SetupScreen", true, false) as SetupScreen
	var cfg := setup.build_config()
	for k in ["mode", "p1_controller", "p2_controller", "p1_model", "p2_model", "rules", "rounds", "round_seconds", "cpu_difficulty", "arena"]:
		check(cfg.has(k), "config has key " + k)
	check(cfg["p1_model"] != cfg["p2_model"], "models differ", str(cfg))
	await press("BtnStart")
	check(main.get_state_name() == "FIGHT", "start opens FIGHT", main.get_state_name())
	check(main.current_match != null and main.current_match.get_fighters().size() == 2, "match with 2 fighters")
	check(main.current_arena is Arena, "arena instanced in slot")
	check(main.current_match.get_node_or_null("PlaceholderArena") == null or main.current_match.get_node("PlaceholderArena").is_queued_for_deletion(), "placeholder arena freed")
	await frames(4)
	check(root.get_viewport().get_camera_3d() == main.current_camera, "fight camera is current")

	# Arena geometry
	await physics_frame
	await physics_frame
	var down := ray(Vector3(0, 2, 0), Vector3(0, -2, 0))
	check(not down.is_empty() and absf(down.position.y) < 0.001, "floor top at y=0", str(down.get("position")))
	for d in [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]:
		var hit := ray(Vector3(0, 1, 0), d * 6.0 + Vector3(0, 1, 0))
		var dist: float = (hit.position as Vector3).length() if not hit.is_empty() else -1.0
		check(not hit.is_empty() and absf(Vector2(hit.position.x, hit.position.z).length() - Arena.WALL_HALF) < 0.001, "wall at Arena.WALL_HALF toward %s" % str(d), str(dist))
	var arena := main.current_arena as Arena
	check(arena.get_node_or_null("Floor") is StaticBody3D, "Floor StaticBody3D")
	check(arena.get_node_or_null("RingWalls") is StaticBody3D, "RingWalls StaticBody3D")
	check(arena.find_children("*", "SpotLight3D", true, false).size() >= 4, "spotlights present")
	check(arena.get_node_or_null("WorldEnvironment") != null, "WorldEnvironment present")

	# Hits drive audio, camera, HUD
	var m := main.current_match
	m.fake_hit(0, "heavy")
	m.fake_hit(1, "medium", "body")
	m.fake_hit(0, "light", "head", true)
	await frames(3)
	check(main.audio.last_played.size() >= 3, "audio played hit sounds", str(main.audio.last_played))
	var pools_ok := true
	for p in ["headHeavySounds", "bodyThudSounds", "gloveBlockSounds"]:
		var a := main.audio.pick(p)
		var b := main.audio.pick(p)
		pools_ok = pools_ok and a != b
	check(pools_ok, "pool never repeats the same file twice")
	check(main.audio.pools.has("koSounds"), "sounds.json pools loaded")
	await frames(10)
	check(main.current_camera.global_position.y > 0.3, "camera above floor")
	var cp := main.current_camera.global_position
	check(maxf(absf(cp.x), absf(cp.z)) >= 3.7, "camera outside the ropes", str(cp))

	# Pause
	main.pause()
	await frames(2)
	check(main.get_state_name() == "PAUSED" and paused, "pause pauses the tree")
	await press("BtnResume")
	check(main.get_state_name() == "FIGHT" and not paused, "resume unpauses")

	# End of match -> results -> rematch -> results -> menu
	m.fake_end(0, "KO")
	await create_timer(0.6).timeout
	check(main.get_state_name() == "RESULTS", "match_ended leads to RESULTS", main.get_state_name())
	await press("BtnRematch")
	check(main.get_state_name() == "FIGHT", "rematch starts a new FIGHT")
	main.current_match.fake_end(1, "Decision")
	await create_timer(0.6).timeout
	check(main.get_state_name() == "RESULTS", "second result shown")
	await press("BtnMenu")
	check(main.get_state_name() == "MENU", "main menu button returns to MENU")
	await frames(3)
	check(main.current_match == null, "match freed on exit")

	# Octagon variant
	var ocfg := cfg.duplicate()
	ocfg["arena"] = "octagon"
	main.start_match(ocfg)
	await frames(4)
	await physics_frame
	await physics_frame
	var oct := main.current_arena as Arena
	check(oct is ArenaOctagon and oct.kind == "octagon", "octagon arena instanced")
	var floor_mi := oct.find_child("octagon_floor*", true, false) as MeshInstance3D
	var top := (floor_mi.global_transform * floor_mi.get_aabb()).end.y if floor_mi else 99.0
	check(absf(top) < 0.03, "octagon canvas top at y=0", str(top))
	var cage := oct.find_child("octagon_cage*", true, false) as MeshInstance3D
	var cbox := cage.global_transform * cage.get_aabb()
	check(absf(cbox.size.x * 0.5 - 4.1) < 0.1, "octagon cage apothem about 4.1", str(cbox.size))
	var wall_hits := 0
	for i in 8:
		var ang := i * PI / 4.0
		var dir := Vector3(cos(ang), 0, sin(ang))
		var hit := ray(Vector3(0, 1, 0), Vector3(0, 1, 0) + dir * 6.0)
		if not hit.is_empty() and absf(Vector2(hit.position.x, hit.position.z).length() - (3.8 - 0.24)) < 0.01:   # colliders sit 0.24 m inside WALL_LIMIT since the fighter capsule shrank to 0.12 m radius
			wall_hits += 1
	check(wall_hits == 8, "8 octagon wall colliders at 3.56 m (3.8 - 0.24 capsule trim)", str(wall_hits))
	main.show_menu()
	await frames(2)

	print("")
	print("%d checks, %d failures" % [checks, failures])
	print("RESULT: ", "PASS" if failures == 0 else "FAIL")
	quit(1 if failures > 0 else 0)
