extends SceneTree
## Windowed contact sheet of raw rig clips (side view), to judge which clip suits which punch variant.
##   godot --path . --script res://tools/render_clips.gd -- "clips=KB_m_Jab_L,KB_p_Jab_L_1" frames=8 span=0.9 name=jabs
## Samples `frames` poses from t=0 to min(len, span) of every clip; one row per clip, written to
## _build/shots/clips_<name>.png

const CELL := Vector2i(300, 360)

func _find_type(n: Node, t: String) -> Node:
	if n.is_class(t):
		return n
	for c in n.get_children():
		var r := _find_type(c, t)
		if r:
			return r
	return null

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var clips: PackedStringArray = []
	var frames := 8
	var span := 0.9
	var nm := "sheet"
	var front := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("clips="):
			clips = a.substr(6).split(",")
		elif a.begins_with("frames="):
			frames = int(a.substr(7))
		elif a.begins_with("span="):
			span = float(a.substr(5))
		elif a == "front":
			front = true
		elif a.begins_with("name="):
			nm = a.substr(5)
	DisplayServer.window_set_size(Vector2i(CELL.x, CELL.y))
	root.size = CELL
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.18, 0.2, 0.24)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.78, 0.85)
	env.ambient_light_energy = 0.6
	var we := WorldEnvironment.new(); we.environment = env; root.add_child(we)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-30, 70, 0); sun.light_energy = 1.4; root.add_child(sun)
	var cam := Camera3D.new(); cam.fov = 38; root.add_child(cam); cam.current = true
	var fighter: Node = (load("res://assets/fighters/viper.glb") as PackedScene).instantiate()
	root.add_child(fighter)
	await process_frame
	var sk: Skeleton3D = _find_type(fighter, "Skeleton3D")
	var ap: AnimationPlayer = _find_type(fighter, "AnimationPlayer")
	var sheet := Image.create(CELL.x * frames, CELL.y * clips.size(), false, Image.FORMAT_RGBA8)
	var row := 0
	for c in clips:
		if not ap.has_animation(c):
			print("missing ", c); row += 1; continue
		var len := ap.get_animation(c).length
		ap.play(c)
		ap.pause()
		for i in frames:
			var t := minf(len, span) * float(i) / float(frames - 1)
			ap.seek(t, true)
			var hip := (sk.global_transform * sk.get_bone_global_pose(sk.find_bone("hip"))).origin
			cam.position = Vector3(1.9, 1.3, hip.z + 2.5) if front else Vector3(3.0, 1.15, hip.z + 0.1)
			cam.look_at(Vector3(0, 1.0, hip.z + 0.1))
			await process_frame
			await RenderingServer.frame_post_draw
			var img := root.get_texture().get_image(); img.convert(Image.FORMAT_RGBA8)
			sheet.blit_rect(img, Rect2i(Vector2i.ZERO, CELL), Vector2i(i * CELL.x, row * CELL.y))
		print("row ", row, " ", c, " len=%.2f" % len)
		row += 1
	sheet.save_png("res://_build/shots/clips_%s.png" % nm)
	quit(0)
