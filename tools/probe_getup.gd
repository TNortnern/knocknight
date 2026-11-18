extends SceneTree
## Prints hip / head position at t=0 and end of the get-up clips and the fall clips (character-local).
func _initialize() -> void:
	_run.call_deferred()
func _run() -> void:
	for mname in ["viper", "anvil"]:
		var m: Node3D = (load("res://assets/fighters/%s.glb" % mname) as PackedScene).instantiate()
		root.add_child(m)
		await process_frame
		var ap: AnimationPlayer = m.find_child("AnimationPlayer", true, false)
		var sk: Skeleton3D = m.find_child("Skeleton3D", true, false)
		print(mname, " skeleton scale ", sk.global_transform.basis.get_scale(), " model scale ", m.scale, " ap root ", ap.root_node)
		for clip in ["KB_GetUpBack", "KB_GetUpFace", "F head KO", "KB_MidKO"]:
			for tt in [0.0, 1.0]:
				var t: float = 0.0 if tt == 0.0 else ap.get_animation(clip).length
				ap.play(clip); ap.seek(t, true); ap.advance(0.0)
				await process_frame
				var hip := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("hip")).origin
				var head := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("head")).origin
				var lf := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("lFoot")).origin
				print("  %-14s t=%.2f hip=(%.3f %.3f %.3f) head-hip=(%.3f %.3f %.3f) lFoot-hip=(%.3f %.3f %.3f) up=%s" % [clip, t, hip.x, hip.y, hip.z, head.x-hip.x, head.y-hip.y, head.z-hip.z, lf.x-hip.x, lf.y-hip.y, lf.z-hip.z, str(load("res://scripts/fighter/knockdown_motion.gd").lying_face_up(sk))])
		m.queue_free()
	quit()
