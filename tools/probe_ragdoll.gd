extends SceneTree
## Dev probe: forces a KO on P2 and prints the body over time.  godot --headless --fixed-fps 120 --path . --script res://tools/probe_ragdoll.gd -- dir=L
var m: Match
func _initialize() -> void:
	_run.call_deferred()
func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		if kv.size() == 2: args[kv[0]] = kv[1]
	m = load("res://scenes/match.tscn").instantiate()
	m.setup({"intro_delay": 0.0, "mode": "exhibition", "rounds": 1, "round_seconds": 600.0, "p1_controller": "dummy", "p2_controller": "dummy"})
	root.add_child(m)
	await process_frame
	var f: Array = m.get_fighters()
	for i in 90: await physics_frame
	var p2: Fighter = f[1]
	print("pos ", p2.global_position, " mass ", p2._ragdoll.total_mass(), " bodies ", p2._ragdoll.bones.size())
	p2._do_ko("KO", args.get("dir", "F"), args.get("zone", "head"))
	var mx := {}
	for i in 120 * 5:
		await physics_frame
		var rdd = p2._ragdoll
		for pr in [["abdomen","pelvis"],["chest","abdomen"],["neck","chest"],["head","neck"],["lThigh","pelvis"],["lUpperArm","chest"]]:
			var ang: float = rad_to_deg((rdd.bones[pr[0]] as PhysicalBone3D).global_basis.get_rotation_quaternion().angle_to((rdd.bones[pr[1]] as PhysicalBone3D).global_basis.get_rotation_quaternion()))
			mx[pr[0]] = maxf(mx.get(pr[0], 0.0), ang)
			if i % 12 == 0 and i < 120: print(i, pr[0], "%.0f" % ang)
		if i % 12 == 0:
			var rd = p2._ragdoll
			var P: Dictionary = rd.body_positions()
			print("t=%.2f pelvis=%s head=%s lfoot=%s chestV=%.2f settled=%s elbowL=%.0f kneeL=%.0f" % [i / 120.0, P["pelvis"].snappedf(0.01), P["head"].snappedf(0.01), P["lFoot"].snappedf(0.01), (rd.bones["chest"] as PhysicalBone3D).linear_velocity.length(), rd.settled(), rd.joint_angle("lForearm"), rd.joint_angle("lShin")])
	print("legs_free ", p2._ragdoll.legs_free, " still ", p2._ragdoll._still_t, " t ", p2._ragdoll.sim_time)
	for id in p2._ragdoll.bones:
		var pb: PhysicalBone3D = p2._ragdoll.bones[id]
		print(id, " lv=%.3f av=%.3f sim=%s" % [pb.linear_velocity.length(), pb.angular_velocity.length(), pb.is_simulating_physics()])
	print("max relative angles (deg, body axes): ", mx)
	quit()
