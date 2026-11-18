extends SceneTree
## Headless: pose distance between each fall clip's last frame and each get-up clip's first frame.
const KM := preload("res://scripts/fighter/knockdown_motion.gd")
func _initialize() -> void:
	_run.call_deferred()
func _run() -> void:
	var m: Node3D = (load("res://assets/fighters/viper.glb") as PackedScene).instantiate()
	root.add_child(m)
	await process_frame
	var ap: AnimationPlayer = m.find_child("AnimationPlayer", true, false)
	var sk: Skeleton3D = m.find_child("Skeleton3D", true, false)
	var falls := ["F head KO", "L head KO", "R head KO", "U head KO", "O head KO", "KB_MidKO", "KB_TopKO", "L Fall", "R Fall"]
	for g in ["KB_GetUpBack", "KB_GetUpFace"]:
		ap.play(g); ap.seek(0.0, true); ap.advance(0.0); await process_frame
		var gp := KM.core_pose(sk)
		for f in falls:
			ap.play(f); ap.seek(ap.get_animation(f).length, true); ap.advance(0.0); await process_frame
			print("%-12s last frame -> %s first frame: %.1f deg  (lying face up: %s -> picks %s)" % [f, g, KM.pose_distance(KM.core_pose(sk), gp), KM.lying_face_up(sk), KM.getup_clip(sk)])
	quit(0)
