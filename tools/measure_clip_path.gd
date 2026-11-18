extends SceneTree
## Prints the punching glove's path (relative to the pelvis, model frame) through a strike's action-time remap,
## so two strikes can be compared frame by frame (wind-up, extension, retraction).
## <godot> --headless --path . --script res://tools/measure_clip_path.gd -- tags=LBodyHook,RBodyHook step=0.02
func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		if kv.size() == 2: args[kv[0]] = kv[1]
	var tags: Array = String(args.get("tags", "LBodyHook,RBodyHook")).split(",")
	var step: float = float(args.get("step", 0.02))
	var p: PackedScene = load("res://assets/fighters/viper.glb")
	var r = p.instantiate()
	get_root().add_child(r)
	await process_frame
	var sk: Skeleton3D = r.find_child("Skeleton3D", true, false)
	var ap: AnimationPlayer = r.find_child("AnimationPlayer", true, false)
	var pelb := sk.find_bone("pelvis")
	var chb := sk.find_bone("chestUpper")
	var lsb := sk.find_bone("lShldrBend")
	var rsb := sk.find_bone("rShldrBend")
	for tag in tags:
		var s: Dictionary
		if String(tag).begins_with("clip:"):   # raw clip at its own speed: "clip:KB_p_MidHook_L:L"
			var parts := String(tag).split(":")
			var ln := ap.get_animation(parts[1]).length
			s = {"clip": parts[1], "limb": parts[2], "action": ln, "t_peak": ln, "clip_peak": ln, "ease": 1.0, "chain": ln}
		else:
			s = StrikeDB.get_strike(tag)
		var clip: String = s["clip"]
		var limb: String = String(s["limb"]).to_lower()
		var tipb := sk.find_bone(limb + "Mid1")
		print("== %s clip=%s action=%.2f t_peak=%.3f clip_peak=%.3f ease=%.2f chain=%.2f" % [tag, clip, s["action"], s["t_peak"], s["clip_peak"], s["ease"], s["chain"]])
		ap.play(clip)
		var prev := Vector3.INF
		var t := 0.0
		while t <= float(s["action"]) + 0.001:
			var ct: float = t if String(tag).begins_with("clip:") else StrikeDB.clip_time(s, t)
			ap.seek(ct, true)
			var g := sk.get_bone_global_pose(tipb).origin - sk.get_bone_global_pose(pelb).origin
			var sp := 0.0 if prev == Vector3.INF else (g - prev).length() / step
			prev = g
			var sh := sk.get_bone_global_pose(lsb).origin - sk.get_bone_global_pose(rsb).origin   # shoulder line: its yaw is the trunk turn
			var chest_y := sk.get_bone_global_pose(chb).origin.y
			print("  t=%.2f clip=%.3f  x=%+.3f y=%+.3f z=%+.3f  reach=%.3f  v=%.2f  shoulder_yaw=%+.0f chest_h=%.3f" % [t, ct, g.x, g.y, g.z, Vector2(g.x, g.z).length(), sp, rad_to_deg(atan2(sh.z, sh.x)), chest_y])
			t += step
	quit()
