extends SceneTree
# Visual proof. Run windowed (NOT --headless):
#   godot --path <project> --script res://tools/render_poses.gd [-- fighter=anvil]
# Writes PNGs to res://_build/renders/<fighter>_<pose>_<view>.png

const POSES := [
	# [label, animation, mode]  mode: "start" = frame 0, "peak:<hand>" = time of max hand distance from chest, "end", "mid"
	["idle", "KB_Idle_1", "start"],
	["jab", "KB_m_Jab_L", "peak:lHand"],
	["hook", "KB_m_Hook_L", "peak:lHand"],
	["ko", "KB_KO_Head", "end"],
	["kick", "KB_m_MidKick_R", "peak:rFoot"],
	["slip", "DEF_slip_left", "mid"],
]
const VIEWS := {
	"front": [Vector3(1.6, 1.25, 2.9), Vector3(0, 0.9, 0)],
	"side": [Vector3(3.2, 1.2, 0.0), Vector3(0, 0.9, 0)],
}

func bone_pos(sk: Skeleton3D, bone: String) -> Vector3:
	return (sk.global_transform * sk.get_bone_global_pose(sk.find_bone(bone))).origin

func find_type(n: Node, t: String) -> Node:
	if n.is_class(t):
		return n
	for c in n.get_children():
		var r := find_type(c, t)
		if r:
			return r
	return null

func _initialize() -> void:
	var fighters := ["viper"]
	for a in OS.get_cmdline_user_args():
		if a.begins_with("fighter="):
			fighters = [a.substr(8)]
	DisplayServer.window_set_size(Vector2i(900, 900))
	root.size = Vector2i(900, 900)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.18, 0.2, 0.24)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.78, 0.85)
	env.ambient_light_energy = 0.6
	var we := WorldEnvironment.new(); we.environment = env; root.add_child(we)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-50, 35, 0); sun.light_energy = 1.4; root.add_child(sun)
	var fill := DirectionalLight3D.new(); fill.rotation_degrees = Vector3(-20, -140, 0); fill.light_energy = 0.6; root.add_child(fill)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new(); plane.size = Vector2(8, 8)
	floor_mesh.mesh = plane
	var fm := StandardMaterial3D.new(); fm.albedo_color = Color(0.35, 0.37, 0.4); floor_mesh.material_override = fm
	root.add_child(floor_mesh)
	# a 1 m marker block at +Z (forward) so facing direction is obvious
	var marker := MeshInstance3D.new(); var bm := BoxMesh.new(); bm.size = Vector3(0.1, 0.1, 0.4); marker.mesh = bm
	marker.position = Vector3(0, 0.05, 1.2)
	var mm := StandardMaterial3D.new(); mm.albedo_color = Color(0.9, 0.2, 0.2); marker.material_override = mm
	root.add_child(marker)
	var cam := Camera3D.new(); cam.fov = 40; root.add_child(cam); cam.current = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_build/renders"))
	await process_frame

	for f in fighters:
		var fighter: Node = (load("res://assets/fighters/%s.glb" % f) as PackedScene).instantiate()
		root.add_child(fighter)
		await process_frame
		var sk: Skeleton3D = find_type(fighter, "Skeleton3D")
		var ap: AnimationPlayer = find_type(fighter, "AnimationPlayer")
		for p in POSES:
			var label: String = p[0]; var anim: String = p[1]; var mode: String = p[2]
			if not ap.has_animation(anim):
				print("missing animation ", anim); continue
			var len := ap.get_animation(anim).length
			ap.play(anim)
			var t := 0.0
			if mode == "end":
				t = len
			elif mode == "mid":
				t = len * 0.3
			elif mode.begins_with("peak:"):
				var hand := mode.substr(5)
				var best := -1.0
				var tt := 0.0
				while tt <= len:
					ap.seek(tt, true)
					var d := (bone_pos(sk, hand) - bone_pos(sk, "hip" if hand.ends_with("Foot") else "chestUpper")).length()
					if d > best:
						best = d; t = tt
					tt += 1.0 / 60.0
			ap.pause()
			ap.seek(t, true)
			await process_frame
			for v in VIEWS:
				var tgt: Vector3 = VIEWS[v][1]
				# follow the hip so travel clips (KO fall) stay in frame
				var hip := bone_pos(sk, "hip")
				var off := Vector3(hip.x, 0, hip.z)
				cam.position = VIEWS[v][0] + off
				cam.look_at(tgt + off)
				await process_frame
				await RenderingServer.frame_post_draw
				var img := root.get_texture().get_image()
				var path := "res://_build/renders/%s_%s_%s.png" % [f, label, v]
				img.save_png(path)
				print("saved ", path, "  t=%.3f" % t)
		fighter.queue_free()
		await process_frame
	quit(0)
