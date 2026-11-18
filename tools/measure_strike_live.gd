extends SceneTree
## Headless: one scripted strike in main.tscn, logged every `every` physics ticks (--fixed-fps 120) through the whole layer
## stack: shoulder-line yaw (deg, fighter frame), the glove relative to the hip (fighter frame: x left, y up, z forward),
## its speed, PunchPose.coil_fix and the hit tick.
##   <godot> --headless --fixed-fps 120 --path . --script res://tools/measure_strike_live.gd -- tag=LBodyHook gap=0.9
func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var i: int = a.find("=")
		if i > 0:
			args[a.substr(0, i)] = a.substr(i + 1)
	var tag: String = args.get("tag", "LBodyHook")
	var gap := float(args.get("gap", "0.9"))
	var every := int(args.get("every", "4"))
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.start_match({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy", "intro_delay": 0.0,
		"p1_model": args.get("att", "meshy_viper"), "p2_model": args.get("foe", "meshy_oak"), "rules": "boxing", "rounds": 1,
		"round_seconds": 600.0, "arena": "ring"})
	await process_frame
	var f: Array = main.current_match.get_fighters()
	var a: Fighter = f[0]
	var d: Fighter = f[1]
	for fi in f:
		fi.stats.infinite_stamina = true
	a.global_position = Vector3(-gap * 0.5, 0, 0)
	d.global_position = Vector3(gap * 0.5, 0, 0)
	a.external_input = FighterInput.new()
	d.external_input = FighterInput.new()
	var hit := [-1]
	var ticks := [0]
	a.hit_landed.connect(func(_att, _inf):
		if hit[0] < 0:
			hit[0] = ticks[0])
	for k in 100:
		await physics_frame
	var sk: Skeleton3D = a.rig.skeleton
	var limb := "l" if tag.begins_with("L") else "r"
	var inp := FighterInput.new()
	inp.strikes.append(tag)
	a.external_input = inp
	var pp = a._punch_pose
	var cur := {"yaw": 0.0, "loc": Vector3.ZERO, "hand": Vector3.ZERO}
	# modifier output only exists inside the skeleton update: read it there (same as meshy_skin.gd)
	sk.skeleton_updated.connect(func():
		var fb := a.global_basis
		var g := sk.global_transform
		var sh := (g * sk.get_bone_global_pose(sk.find_bone("lShldrBend")).origin) - (g * sk.get_bone_global_pose(sk.find_bone("rShldrBend")).origin)
		var hand := g * sk.get_bone_global_pose(sk.find_bone(limb + "Hand")).origin
		var rel := hand - g * sk.get_bone_global_pose(sk.find_bone("hip")).origin
		cur["yaw"] = rad_to_deg(atan2(sh.dot(fb.z), sh.dot(fb.x)))
		cur["loc"] = Vector3(rel.dot(fb.x), rel.dot(fb.y), rel.dot(fb.z))
		cur["hand"] = hand)
	var prev := Vector3.INF
	for k in 120:
		if k == 1:
			a.external_input = FighterInput.new()
		await physics_frame
		inp.strikes.clear()   # one throw: a process frame can hold two physics ticks, the second would queue it again
		await process_frame
		ticks[0] += 1
		var loc: Vector3 = cur["loc"]
		var hand: Vector3 = cur["hand"]
		var v := 0.0 if prev == Vector3.INF else (hand - prev).length() * 120.0
		prev = hand
		if k % every == 0:
			var ih = sk.get_node_or_null("ImpactHold")
			var ihs: Vector3 = ih.last_shift if ih != null else Vector3.ZERO
			print("t=%.3f st=%s yaw=%+.0f glove x=%+.2f y=%+.2f z=%+.2f v=%.1f shift=%.2f phase=%s coil_fix=%.0f%s" % [k / 120.0, a.state, cur["yaw"], loc.x, loc.y, loc.z, v, ihs.length(), a.punch_phase(),
				rad_to_deg(float(pp.get("coil_fix")) if pp.get("coil_fix") != null else 0.0), "  HIT" if hit[0] >= 0 and hit[0] > k - every else ""])
		if k > 80 and a.state != a.State.ATTACK:
			break
	print("hit_tick=", hit[0], " (", hit[0] / 120.0, " s)")
	quit(0)
