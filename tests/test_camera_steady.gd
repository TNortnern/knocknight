extends SceneTree
# Side-view camera (Fight Night style): during a 60 s CPU fight the shot stays square to the fighters, P1 on the left,
# never swaps sides, and turns smoothly (no whips, no jumps).
# godot --headless --fixed-fps 120 --path . --script res://tests/test_camera_steady.gd [-- secs=60 p1=meshy_oak p2=meshy_viper]
# Prints PASS/FAIL and exits 0 / 1.

var failures := 0
var main: Node


func check(ok: bool, msg: String) -> void:
	if ok:
		print("  ok   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1


func _initialize() -> void:
	_run.call_deferred()


func _yaw_of(c: Camera3D) -> float:
	var f := -c.global_transform.basis.z
	return atan2(f.x, f.z)


func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	var secs := float(args.get("secs", "60"))
	main = load("res://scenes/main.tscn").instantiate()
	get_root().add_child(main)
	await process_frame
	main.start_match({"intro_delay": 0.0, "mode": "exhibition", "rounds": 1, "round_seconds": 600.0, "rules": "boxing",
		"p1_model": args.get("p1", "meshy_oak"), "p2_model": args.get("p2", "meshy_viper"), "arena": "ring",
		"p1_controller": "cpu", "p2_controller": "cpu", "cpu_difficulty": "hard"})
	await process_frame
	var cam: FightCamera = main.current_camera
	var m: Match = main.current_match
	var fighters: Array = m.get_fighters()
	for f in fighters:
		f.stats.infinite_stamina = false
	var win := 30            # 0.25 s windows at 120 fps
	var hist_yaw: Array = []
	var hist_pos: Array = []
	var prev_pos := cam.global_position
	var prev_yaw := _yaw_of(cam)
	var t := 0.0
	var dt := 1.0 / 120.0
	var sum_rate := 0.0
	var n_rate := 0
	var max_rate := 0.0
	var max_jump := 0.0
	var path := 0.0
	var calm_frames := 0
	var yaw_total := 0.0
	var bad_frames := 0
	var ended := false
	var line_travel := 0.0
	var flips := 0
	var prev_side: float = cam._side
	var close_travel := 0.0
	var close_t := 0.0
	var prev_line := 0.0
	var side_on := 0
	var p1_left := 0
	var side_n := 0
	var max_obl := 0.0
	var far_n := 0
	var far_on := 0
	m.match_ended.connect(func(_r): ended = true)
	while t < secs and not ended:
		await process_frame
		t += dt
		var p := cam.global_position
		var y := _yaw_of(cam)
		var jump := p.distance_to(prev_pos)
		if cam._side != prev_side:
			flips += 1
			prev_side = cam._side
		var dy := angle_difference(prev_yaw, y)
		prev_pos = p
		var lraw := atan2(fighters[1].global_position.x - fighters[0].global_position.x, fighters[1].global_position.z - fighters[0].global_position.z)
		if t > dt * 2.0:
			var dd := absf(rad_to_deg(angle_difference(prev_line, lraw)))
			line_travel += dd
			if fighters[0].gap_to_foe() < 1.0:
				close_travel += dd
				close_t += dt
		prev_line = lraw
		if int(t*120) % 600 == 0 and args.has('dbg'):
			print('t=%.2f yaw=%.1f goal=%.1f line=%.1f side=%d mode=%d extra=%.2f pos=%s' % [t, rad_to_deg(y), rad_to_deg(cam._goal_yaw), rad_to_deg(cam._line_yaw), int(cam._side), cam.mode, cam._extra, p])
		prev_yaw = y
		hist_yaw.append(dy)
		hist_pos.append(jump)
		var special: bool = cam.mode != FightCamera.Mode.LIVE or cam.impact.active()
		for f in fighters:
			if f.rocked or f.is_acute_down() or f.is_out():
				special = true
		if special:
			bad_frames += 1
			hist_yaw[hist_yaw.size() - 1] = 0.0   # excluded from the rate (window keeps its length)
			continue
		calm_frames += 1
		# side-on: the view direction stays square to the fighters' line; P1 stays on screen-left
		var fwd := -cam.global_transform.basis.z
		fwd.y = 0.0
		var ln: Vector3 = fighters[1].global_position - fighters[0].global_position
		ln.y = 0.0
		if fwd.length() > 0.01 and ln.length() > 0.3:
			var obl := absf(90.0 - rad_to_deg(fwd.normalized().angle_to(ln.normalized())))
			max_obl = maxf(max_obl, obl)
			if obl < 20.0:
				side_on += 1
			if fighters[0].gap_to_foe() >= 1.0:
				far_n += 1
				if obl < 20.0:
					far_on += 1
			var right := cam.global_transform.basis.x
			if ((fighters[0].global_position - fighters[1].global_position) as Vector3).dot(right) < 0.0:
				p1_left += 1
			side_n += 1
		max_jump = maxf(max_jump, jump)
		path += jump
		yaw_total += absf(dy)
		if hist_yaw.size() >= win:
			var s := 0.0
			for i in range(hist_yaw.size() - win, hist_yaw.size()):
				s += hist_yaw[i]
			var rate := absf(rad_to_deg(s)) / (win * dt)
			max_rate = maxf(max_rate, rate)
	var mean_rate := rad_to_deg(yaw_total) / maxf(calm_frames * dt, 0.001)
	print("    simulated %.1f s (%d calm frames, %d rock/KO frames)" % [t, calm_frames, bad_frames])
	print("    mean |yaw rate| %.2f deg/s, max over 0.25 s %.1f deg/s, max per-frame jump %.3f m, mean cam speed %.2f m/s" % [mean_rate, max_rate, max_jump, path / maxf(calm_frames * dt, 0.001)])
	print("    fighters line travel %.0f deg total (%.1f deg/s)" % [line_travel, line_travel / maxf(t, 0.01)])
	print("    camera side flips: %d" % flips)
	print("    of which gap<1.0 m: %.0f deg in %.1f s" % [close_travel, close_t])
	check(calm_frames > 120 * 20, "enough live frames measured")
	# owner (2026-10-28): "a side view, consistently" -- the shot turns with the fighters, smoothly, never oblique
	var on_frac := float(side_on) / maxf(side_n, 1.0)
	var left_frac := float(p1_left) / maxf(side_n, 1.0)
	var far_frac := float(far_on) / maxf(far_n, 1.0)
	print("    side-on (<20 deg oblique) %.1f%% of frames (%.1f%% at range >= 1 m), worst %.0f deg; P1 on screen-left %.1f%%" % [on_frac * 100.0, far_frac * 100.0, max_obl, left_frac * 100.0])
	check(on_frac >= 0.85, "side view (< 20 deg off square) >= 85%% of live frames (%.1f%%)" % (on_frac * 100.0))
	check(max_obl < 45.0, "never oblique enough to hide a fighter behind the other (worst %.0f deg < 45)" % max_obl)
	check(left_frac >= 0.98, "P1 stays on screen-left (%.1f%%)" % (left_frac * 100.0))
	check(flips == 0, "the camera never swaps sides mid-fight (%d)" % flips)
	check(max_rate < 90.0, "smooth: max yaw rate (0.25 s window) < 90 deg/s (%.1f)" % max_rate)
	check(max_jump < 0.3, "no camera jump > 0.3 m per frame (%.3f)" % max_jump)
	print("PASS" if failures == 0 else "FAIL (%d)" % failures)
	quit(0 if failures == 0 else 1)
