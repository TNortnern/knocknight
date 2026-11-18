extends SceneTree
## Headless: for every fall / KO / get-up clip print the lying orientation at sampled times.
## <godot> --headless --path . --script res://tools/analyze_fall_clips.gd [-- model=viper clips=a,b]
func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		if kv.size() == 2: args[kv[0]] = kv[1]
	var packed: PackedScene = load("res://assets/fighters/%s.glb" % args.get("model", "viper"))
	var m: Node3D = packed.instantiate()
	root.add_child(m)
	await process_frame
	var ap: AnimationPlayer = m.find_child("AnimationPlayer", true, false)
	var sk: Skeleton3D = m.find_child("Skeleton3D", true, false)
	if args.has("bones"):
		for i in sk.get_bone_count(): print(i, " ", sk.get_bone_name(i))
		quit(0); return
	var names: Array = []
	if args.has("clips"):
		names = String(args["clips"]).split(",")
	else:
		for n in ap.get_animation_list():
			var s := String(n)
			if s.contains("Fall") or s.contains("KO") or s.contains("GetUp") or s.contains("Stagger"):
				names.append(s)
	names.sort()
	var hip := sk.find_bone("hip")
	var head := sk.find_bone("head")
	var ls := sk.find_bone("lShldrBend")
	var rs := sk.find_bone("rShldrBend")
	var sign_ := 1.0
	ap.play("KB_Idle_1"); ap.seek(0.0, true); ap.advance(0.0); await process_frame
	if _front(sk, hip, head, ls, rs, 1.0).z < 0.0: sign_ = -1.0
	print("front sign ", sign_)
	for n in names:
		var a := ap.get_animation(n)
		var line := "%-28s %.2fs" % [n, a.length]
		for tf in [0.0, 0.3, 0.6, 0.8, 1.0]:
			ap.play(n)
			ap.seek(tf * a.length, true)
			ap.advance(0.0)
			await process_frame
			var hp: Vector3 = sk.get_bone_global_pose(hip).origin
			var hd: Vector3 = sk.get_bone_global_pose(head).origin
			var fr := _front(sk, hip, head, ls, rs, sign_)
			var u := (hd - hp).normalized()
			line += " | hip(%+.2f,%.2f,%+.2f) up.y%+.2f fr.y%+.2f hdZ%+.2f hdX%+.2f" % [hp.x, hp.y, hp.z, u.y, fr.y, hd.z - hp.z, hd.x - hp.x]
		print(line)
	quit(0)


func _front(sk: Skeleton3D, hip: int, head: int, ls: int, rs: int, sg: float) -> Vector3:
	var hp: Vector3 = sk.get_bone_global_pose(hip).origin
	var hd: Vector3 = sk.get_bone_global_pose(head).origin
	var s: Vector3 = sk.get_bone_global_pose(ls).origin - sk.get_bone_global_pose(rs).origin
	return (s.cross(hd - hp)).normalized() * sg
