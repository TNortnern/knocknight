extends SceneTree
## Headless probe: CPU vs CPU for `secs` game seconds, samples every fighter's FINAL skeleton pose (inside
## Skeleton3D.skeleton_updated) each frame: hip height, knee heights, trunk pitch. Prints the lowest values per state.
## godot --headless --fixed-fps 120 --path . --script res://tools/probe_pose_limits.gd -- secs=60 seed=1
var data := {}   ## fighter id -> {hip, lknee, rknee, state}
var stats := {}  ## state name -> {n, hip_min, knee_min, hip_below}

func _initialize() -> void:
	_run.call_deferred()

var _fighters := {}
func _pitch(fid: int, g: Transform3D, sk: Skeleton3D) -> float:
	var f: Node3D = _fighters[fid]
	var v: Vector3 = f.global_basis.inverse() * (g.basis * (sk.get_bone_global_pose(sk.find_bone("chestUpper")).origin - sk.get_bone_global_pose(sk.find_bone("hip")).origin))
	return atan2(v.z, v.y)

func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		if kv.size() == 2: args[kv[0]] = kv[1]
	var secs := float(args.get("secs", "60"))
	var limit := float(args.get("limit", "0.62"))
	var m = load("res://scenes/match.tscn").instantiate()
	m.setup({"intro_delay": 0.0, "mode": "exhibition", "rounds": 1, "round_seconds": 600.0, "p1_controller": "cpu", "p2_controller": "cpu",
		"p1_model": "viper", "p2_model": "anvil", "rules": args.get("rules", "boxing"), "cpu_difficulty": args.get("diff", "hard")})
	root.add_child(m)
	await process_frame
	var fs: Array = m.get_fighters()
	for f in fs:
		var sk: Skeleton3D = f.rig.skeleton
		var fid: int = f.get_instance_id()
		_fighters[fid] = f
		sk.skeleton_updated.connect(func():
			if not sk.is_inside_tree(): return
			var g := sk.global_transform
			data[fid] = {"hip": (g * sk.get_bone_global_pose(sk.find_bone("hip")).origin).y,
				"lk": (g * sk.get_bone_global_pose(sk.find_bone("lShin")).origin).y,
				"rk": (g * sk.get_bone_global_pose(sk.find_bone("rShin")).origin).y,
				"pitch": rad_to_deg(_pitch(fid, g, sk))})
	if args.get("nopunch", "0") == "1":
		for f in fs: f._punch_pose.active = false
	var n := int(secs * Engine.physics_ticks_per_second)
	var worst := {}
	for i in n:
		await physics_frame
		for f in fs:
			var d: Dictionary = data.get(f.get_instance_id(), {})
			if d.is_empty(): continue
			var sn: String = f.state_name
			if sn in ["fall", "count", "getup", "down", "win", "lose"]: continue
			var s: Dictionary = stats.get(sn, {"n": 0, "hip": 9.0, "knee": 9.0, "below": 0, "pitch": -99.0})
			s["n"] += 1
			s["hip"] = minf(s["hip"], d["hip"])
			s["knee"] = minf(s["knee"], minf(d["lk"], d["rk"]))
			s["pitch"] = maxf(s["pitch"], d["pitch"])
			if d["hip"] < limit: s["below"] += 1
			var kn := minf(d["lk"], d["rk"])
			if kn < float(args.get("kneelimit", "0.22")):
				var clip := String(f.atk["s"].get("clip", "?")) if not f.atk.is_empty() else "-"
				var key := "%s|%s" % [sn, clip]
				worst[key] = worst.get(key, 0) + 1
				if kn < s["knee"] + 0.001:
					s["why"] = "clip=%s dip=%.2f gs=%.3f hinge=%.2f shell=%.2f fat=%.2f" % [clip, f._punch_pose.w_dip, f.guard_style.hip_offset, f.dm.pose.hinge, f.dm.pose.shell, f.fatigue]
			stats[sn] = s
	print("low-knee frames by state|clip: ", worst)
	for k in stats:
		print("%-10s n=%5d hip_min=%.3f knee_min=%.3f pitch_max=%.1f hip<%.2f: %d %s" % [k, stats[k]["n"], stats[k]["hip"], stats[k]["knee"], stats[k]["pitch"], limit, stats[k]["below"], stats[k].get("why", "")])
	quit(0)
