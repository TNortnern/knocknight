extends SceneTree
## Headless probe of one scripted KO: prints the pelvis / head track every 0.1 s in the fall frame (back = away from the
## attacker, lat = along the blow's side) plus knee flexion, and the rest summary.
## godot --headless --fixed-fps 120 --path . --script res://tools/probe_ko.gd -- punch=RHook gap=0.8 off=0.25 [mode=ko|body] [verbose=1]
func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		if kv.size() == 2: args[kv[0]] = kv[1]
	var punch: String = args.get("punch", "RHook")
	var gap := float(args.get("gap", "0.85"))
	var off := float(args.get("off", "0.0"))
	var verbose: bool = args.get("verbose", "0") == "1"
	var m = load("res://scenes/match.tscn").instantiate()
	m.setup({"intro_delay": 0.0, "mode": "exhibition", "rounds": 1, "round_seconds": 600.0, "p1_controller": "dummy", "p2_controller": "dummy",
		"p1_model": "viper", "p2_model": "anvil", "rules": "boxing"})
	root.add_child(m)
	await process_frame
	var f: Array = m.get_fighters()
	var p1: Fighter = f[0]
	var p2: Fighter = f[1]
	p1.external_input = FighterInput.new()
	p2.external_input = FighterInput.new()
	p1.stats.infinite_stamina = true
	p2.stats.infinite_stamina = true
	for i in 90: await physics_frame
	p1.global_position = Vector3(-gap * 0.5, 0, off * 0.5)
	p2.global_position = Vector3(gap * 0.5, 0, -off * 0.5)
	for i in 60: await physics_frame
	var start := p2.global_position
	if String(args.get("mode", "ko")) == "body":
		p2.stats.body_max = 0.0
	else:
		p2.stats.head = 0.4
		p2.stats.knockdowns = 3
	p1.external_input.strikes.append(punch)
	await physics_frame
	p1.external_input.strikes.clear()
	var n := 0
	while p2.state != Fighter.State.DOWN and n < 600:
		await physics_frame
		n += 1
	var rd = p2._ragdoll
	var back: Vector3 = rd._back
	var lat: Vector3 = rd._lat
	print("kind=%s side=%.0f back=(%.2f,%.2f)" % [rd.kind, rd._side, back.x, back.z])
	var ymax := 0.0
	var vmax := 0.0
	for i in 6 * 12:
		await physics_frame
		for id in rd.bones:
			var b: PhysicalBone3D = rd.bones[id]
			ymax = maxf(ymax, b.global_position.y)
			vmax = maxf(vmax, b.linear_velocity.length())
		if verbose and i % int(args.get('every', '12')) == 0:
			var pel: Vector3 = rd.pelvis_position() - start
			var hd: Vector3 = rd.head_position() - start
			if args.get("omega", "0") == "1":
				var line := ""
				for id in rd.bones:
					line += "%s:%.1f " % [id, (rd.bones[id] as PhysicalBone3D).angular_velocity.length()]
				print("   w ", line)
			if args.get("ys", "0") == "1" and i > 40 and i < 70:
				var l2 := ""
				for id in ["pelvis", "lThigh", "lShin", "lFoot", "rThigh", "rShin", "rFoot", "chest"]:
					var pb: PhysicalBone3D = rd.bones[id]
					l2 += "%s y%.2f v(%.1f,%.1f,%.1f) | " % [id, pb.global_position.y, pb.linear_velocity.x, pb.linear_velocity.y, pb.linear_velocity.z]
				print("   ", l2)
			if args.get("axis", "0") == "1":
				var th: PhysicalBone3D = rd.bones["lThigh"]
				var sh: PhysicalBone3D = rd.bones["lShin"]
				var rel: Basis = th.global_basis.orthonormalized().inverse() * sh.global_basis.orthonormalized()
				var q := rel.get_rotation_quaternion()
				var ax: Vector3 = q.get_axis() if q.get_angle() > 0.02 else Vector3.ZERO
				print("   rel knee axis (thigh local) %s ang %.0f ; skeleton axis x in world %s" % [ax, rad_to_deg(q.get_angle()), (rd.skeleton.global_basis * Vector3(1,0,0))])
			print("t=%.1f pelvis b=%.2f l=%.2f y=%.2f | head b=%.2f l=%.2f y=%.2f | knee %.0f %.0f" % [i / 120.0, pel.dot(back), pel.dot(lat), pel.y, hd.dot(back), hd.dot(lat), hd.y, rd.knee_flex("l"), rd.knee_flex("r")])
	await create_timer(0.0).timeout
	for i in 120 * 3: await physics_frame
	var pel: Vector3 = rd.pelvis_position() - start
	var hd: Vector3 = rd.head_position() - start
	var slide := Vector2(pel.x, pel.z).length()
	print("ymax=%.2f vmax=%.1f" % [ymax, vmax])
	print("REST %s: slide=%.2f pelvis b=%.2f l=%.2f | head b=%.2f l=%.2f | chest_ny=%.2f %s" % [punch, slide, pel.dot(back), pel.dot(lat), hd.dot(back), hd.dot(lat), (rd.bones["chest"] as PhysicalBone3D).global_basis.z.y, "up" if rd.lying_face_up() else "DOWN"])
	quit(0)
