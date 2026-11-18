extends SceneTree
## Actual CPU exhibition at the gameplay camera with chosen models (p1= p2=), for before/after look checks. Visual capture only.
## godot --path . --fixed-fps 120 --script res://tools/capture_look_fight.gd -- p1=meshy_viper p2=meshy_anvil out=C:/absolute/frames

var out_dir := ""
var fps := 10
var seconds := 10.0
var p1 := "meshy_viper"
var p2 := "meshy_anvil"
const CaptureMainScript := preload("res://tools/capture_fn_main.gd")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for arg in OS.get_cmdline_user_args():
		var pair := String(arg).split("=", true, 1)
		if pair.size() < 2:
			continue
		match pair[0]:
			"out": out_dir = pair[1]
			"fps": fps = clampi(int(pair[1]), 1, 120)
			"seconds": seconds = clampf(float(pair[1]), 0.1, 60.0)
			"p1": p1 = pair[1]
			"p2": p2 = pair[1]
	if out_dir.is_empty() or not out_dir.is_absolute_path():
		push_error("capture_look_fight: out must be an absolute directory")
		quit(2)
		return
	if DirAccess.make_dir_recursive_absolute(out_dir) != OK:
		quit(2)
		return
	Engine.physics_ticks_per_second = 120
	Engine.max_physics_steps_per_frame = 1
	Engine.physics_jitter_fix = 0.0
	root.size = Vector2i(1280, 720)
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.set_script(CaptureMainScript)
	root.add_child(main)
	await process_frame
	main.start_match({"mode": "exhibition", "p1_controller": "cpu", "p2_controller": "cpu",
		"p1_model": p1, "p2_model": p2, "rules": "boxing",
		"rounds": 1, "round_seconds": 120.0, "cpu_difficulty": "hard", "arena": "ring", "intro_delay": 0.0})
	await process_frame
	await RenderingServer.frame_post_draw
	var matches := main.find_children("*", "Match", true, false)
	if matches.is_empty():
		quit(2)
		return
	var match_node = matches[0]
	var fighters: Array = match_node.get_fighters()
	var start_process := Engine.get_process_frames()
	var start_physics := Engine.get_physics_frames()
	var frames := []
	for i in int(ceilf(seconds * fps)):
		var target := start_process + int(round(float(i) * 120.0 / fps))
		while Engine.get_process_frames() < target:
			await process_frame
		await RenderingServer.frame_post_draw
		var path := out_dir.path_join("cpu_%03d.png" % i)
		root.get_texture().get_image().save_png(path)
		var states := []
		for f in fighters:
			states.append({"model": f.model, "state": f.state_name, "attack": f.atk.get("tag", ""),
				"lean": [f.lean_pose.pos.x, f.lean_pose.pos.y], "root": [f.position.x, f.position.y, f.position.z]})
		frames.append({"index": i, "image": path,
			"time": float(Engine.get_process_frames() - start_process) / 120.0,
			"physics_tick": Engine.get_physics_frames() - start_physics,
			"time_scale": Engine.time_scale, "fighters": states})
	var file := FileAccess.open(out_dir.path_join("sequence_manifest.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"schema": "knocknight_visual_cpu/v1", "fps": fps,
		"created_utc": Time.get_datetime_string_from_system(true), "frame_count": frames.size(),
		"sampling": "120 fixed render frames/sec; sampled process-frame indices; gameplay time dips retained",
		"camera": "actual gameplay FightCamera", "ui": "actual gameplay HUD and world status tags",
		"code_assertions": false, "frames": frames}, "\t", true))
	file.close()
	print("capture_look_fight: wrote ", frames.size(), " frames to ", out_dir)
	quit(0)
