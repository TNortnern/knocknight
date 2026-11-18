extends SceneTree
## For each hand strike: where in its own clip the glove is furthest from the guard (clip peak) and when it is back
## within 40 / 20 / 10 % of that distance. Tells how much of a clip's tail is the arm returning vs the body settling.
## <godot> --headless --path . --script res://tools/measure_clip_return.gd
func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var r = (load("res://assets/fighters/viper.glb") as PackedScene).instantiate()
	get_root().add_child(r)
	await process_frame
	var sk: Skeleton3D = r.find_child("Skeleton3D", true, false)
	var ap: AnimationPlayer = r.find_child("AnimationPlayer", true, false)
	var pelb := sk.find_bone("pelvis")
	for tag in StrikeDB.CORE_HAND + StrikeDB.CORE_BODY:
		var s := StrikeDB.get_strike(tag)
		var tipb := sk.find_bone(String(s["limb"]).to_lower() + "Mid1")
		var ln: float = ap.get_animation(s["clip"]).length
		ap.play(s["clip"])
		var pts: Array = []
		var t := 0.0
		while t <= ln + 0.0001:
			ap.seek(t, true)
			pts.append(sk.get_bone_global_pose(tipb).origin - sk.get_bone_global_pose(pelb).origin)
			t += 0.01
		var g0: Vector3 = pts[0]
		var far := 0.0
		var ifar := 0
		for i in pts.size():
			if (pts[i] - g0).length() > far:
				far = (pts[i] - g0).length()
				ifar = i
		var back := [-1.0, -1.0, -1.0]
		var fr := [0.4, 0.2, 0.1]
		for j in 3:
			for i in range(ifar, pts.size()):
				if (pts[i] - g0).length() < far * fr[j]:
					back[j] = i * 0.01
					break
		print("%-14s len %.2f  peak(table) %.2f  far %.2f (%.2f m)  back40 %.2f  back20 %.2f  back10 %.2f" % [tag, ln, s["clip_peak"], ifar * 0.01, far, back[0], back[1], back[2]])
	quit()
