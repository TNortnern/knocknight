extends SceneTree
## Headless: touchdown (hip < 0.25 m) and settle time (last time a core bone moves > 0.4 deg/frame) per clip.
## <godot> --headless --path . --script res://tools/clip_timing.gd -- clips=a,b
const KM := preload("res://scripts/fighter/knockdown_motion.gd")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		if kv.size() == 2: args[kv[0]] = kv[1]
	var m: Node3D = (load("res://assets/fighters/%s.glb" % args.get("model", "viper")) as PackedScene).instantiate()
	root.add_child(m)
	await process_frame
	var ap: AnimationPlayer = m.find_child("AnimationPlayer", true, false)
	var sk: Skeleton3D = m.find_child("Skeleton3D", true, false)
	var bones: Array = []
	for b in KM.CORE_BONES: bones.append(sk.find_bone(b))
	var hip := sk.find_bone("hip")
	for n in String(args.get("clips", "")).split(","):
		var a := ap.get_animation(n)
		var frames := int(a.length * 30.0)
		var prev: Array = []
		var land := -1.0
		var settle := 0.0
		var ymin := 9.0
		for f in frames + 1:
			var t := minf(f / 30.0, a.length)
			ap.play(n); ap.seek(t, true); ap.advance(0.0)
			await process_frame
			var y: float = sk.get_bone_global_pose(hip).origin.y
			ymin = minf(ymin, y)
			if land < 0.0 and y < 0.25: land = t
			var cur: Array = []
			for b in bones: cur.append(sk.get_bone_pose_rotation(b))
			if not prev.is_empty():
				var mx := 0.0
				for i in cur.size(): mx = maxf(mx, rad_to_deg((cur[i] as Quaternion).angle_to(prev[i])))
				if mx > 2.0: settle = t
			prev = cur
		print("%-14s len %.2f  land %.2f  settle %.2f  hip_ymin %.2f" % [n, a.length, land, settle, ymin])
	quit(0)
