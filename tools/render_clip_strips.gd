extends SceneTree
## Windowed: renders N evenly spaced frames of each clip as a strip (side view and front view) to
## _build/strips/<clip>_side.png / _front.png.
## <godot> --path . --script res://tools/render_clip_strips.gd -- clips="L Fall,R Fall" n=10 model=viper
const SP := 2.0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		if kv.size() == 2: args[kv[0]] = kv[1]
	var n: int = int(args.get("n", 10))
	var clips: Array = String(args.get("clips", "L Fall")).split(",")
	var W := 1800
	var H := 420
	DisplayServer.window_set_size(Vector2i(W, H))
	root.size = Vector2i(W, H)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.18, 0.2, 0.24)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.78, 0.85)
	env.ambient_light_energy = 0.7
	var we := WorldEnvironment.new(); we.environment = env; root.add_child(we)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-50, 35, 0); sun.light_energy = 1.4; root.add_child(sun)
	var fl := MeshInstance3D.new()
	var pl := PlaneMesh.new(); pl.size = Vector2(60, 60); fl.mesh = pl
	var fm := StandardMaterial3D.new(); fm.albedo_color = Color(0.35, 0.37, 0.4); fl.material_override = fm
	root.add_child(fl)
	var cam := Camera3D.new(); cam.projection = Camera3D.PROJECTION_ORTHOGONAL; cam.size = SP * n * H / float(W) * 1.0
	root.add_child(cam); cam.current = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_build/strips"))
	var packed: PackedScene = load("res://assets/fighters/%s.glb" % args.get("model", "viper"))
	for clip in clips:
		var figs: Array = []
		var aps: Array = []
		for i in n:
			var m: Node3D = packed.instantiate()
			root.add_child(m)
			figs.append(m)
			aps.append(m.find_child("AnimationPlayer", true, false))
		await process_frame
		for view in ["side", "front"]:
			for i in n:
				var ap: AnimationPlayer = aps[i]
				var len := ap.get_animation(clip).length
				var x := (i - (n - 1) * 0.5) * SP
				if view == "side":
					figs[i].position = Vector3(0, 0, x)
				else:
					figs[i].position = Vector3(x, 0, 0)
				ap.play(clip)
				ap.seek(len * i / float(n - 1), true)
				ap.advance(0.0)
				ap.pause()
			if view == "side":
				cam.position = Vector3(-10, 0.9, 0); cam.look_at(Vector3(0, 0.9, 0))
			else:
				cam.position = Vector3(0, 0.9, 10); cam.look_at(Vector3(0, 0.9, 0))
			await process_frame
			await process_frame
			root.get_viewport().get_texture().get_image().save_png("res://_build/strips/%s_%s.png" % [clip.replace(" ", "_"), view])
		for m in figs: m.queue_free()
		await process_frame
	quit(0)
