extends SceneTree
# godot --headless --path . --script res://tools/measure_gait.gd : planted-foot speed of each locomotion clip (m/s)

func _initialize() -> void:
	var root: Node = (load("res://assets/fighters/viper.glb") as PackedScene).instantiate()
	get_root().add_child(root)
	await process_frame
	var sk: Skeleton3D = root.find_child("Skeleton3D", true, false)
	var ap: AnimationPlayer = root.find_child("AnimationPlayer", true, false)
	var feet := [sk.find_bone("lFoot"), sk.find_bone("rFoot")]
	var hip := sk.find_bone("hip")
	for clip in ["KB_Idle_1", "KB_WalkFwd2", "KB_WalkBwd", "KB_Sidestep_L", "KB_WalkLeft45", "KB_WalkLeft135", "KB_WalkRight45", "KB_WalkRight135"]:
		var a := ap.get_animation(clip)
		ap.play(clip)
		var n := int(a.length * 60.0)
		var prev := [Vector3.ZERO, Vector3.ZERO]
		var speeds: Array = []
		for i in n + 1:
			ap.seek(float(i) / 60.0, true)
			var cur := []
			for fb in feet:
				cur.append(sk.get_bone_global_pose(fb).origin - sk.get_bone_global_pose(hip).origin * Vector3(1, 0, 1))
			if i > 0:
				for k in 2:
					if cur[k].y < 0.1 and prev[k].y < 0.1:
						speeds.append(Vector2(cur[k].x - prev[k].x, cur[k].z - prev[k].z).length() * 60.0)
			prev = cur
		speeds.sort()
		var med: float = speeds[speeds.size() / 2] if speeds.size() > 0 else 0.0
		print("%-18s len %.2f  planted-foot speed median %.2f m/s (%d samples)" % [clip, a.length, med, speeds.size()])
	quit()
