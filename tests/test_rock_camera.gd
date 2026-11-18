extends SceneTree
const ImpactModel := preload("res://scripts/camera/impact_model.gd")
const StubMatch := preload("res://tests/stubs/stub_match.tscn")
# Rocked / impact camera presentation (port of web impact.js CAMERA60).
# godot --headless --path . --script res://tests/test_rock_camera.gd
# Prints PASS/FAIL and exits 0 / 1.

var failures := 0


func check(ok: bool, msg: String) -> void:
	if ok:
		print("  ok   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1


func near(a: float, b: float, eps: float) -> bool:
	return absf(a - b) <= eps


## a fresh model with one rock cue, advanced to time t in 1/240 s steps
func rock_at(t: float, quality := 1.0, dir := 1.0) -> RefCounted:
	var m := ImpactModel.new()
	m.consume({"attacker": 0, "kind": "rock", "quality": quality, "dir_sign": dir})
	var n := int(round(t * 240.0))
	for i in n:
		m.step(1.0 / 240.0)
	return m


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("-- envelopes")
	check(near(ImpactModel.rock_push_envelope(ImpactModel.ROCK_IN), 1.0, 1e-6), "push envelope reaches 1 at rockIn (.113)")
	check(near(ImpactModel.rock_push_envelope(0.3), 1.0, 1e-6), "push envelope holds through .45")
	check(ImpactModel.rock_push_envelope(0.8) == 0.0 and ImpactModel.rock_push_envelope(0.0) == 0.0, "push envelope is 0 at start and from .8 s")
	check(near(ImpactModel.rock_tilt_envelope(0.5), 8.5, 1e-6), "tilt envelope 8.5 deg at 0.5 s")
	check(near(ImpactModel.rock_tilt_envelope(1.4), -7.0, 1e-6), "tilt envelope -7 deg at 1.4 s")
	check(near(ImpactModel.rock_tilt_envelope(2.4), 0.0, 1e-6) and ImpactModel.rock_tilt_envelope(3.0) == 0.0, "tilt envelope 0 at 2.4 s and beyond")
	check(ImpactModel.rock_tilt_envelope(0.3) == 0.0, "tilt not started before .32 s")
	check(ImpactModel.camera_envelope(ImpactModel.PEAK) > 0.99, "kick envelope peaks at 94 ms")
	check(ImpactModel.camera_envelope(0.5) == 0.0, "kick envelope gone by .48 s")
	check(near(ImpactModel.blur_envelope(0.03), 1.0, 1e-6) and near(ImpactModel.blur_envelope(0.1), 0.18, 1e-6) and ImpactModel.blur_envelope(0.41) == 0.0, "blur envelope 1 / .18 / 0")

	print("-- rock sequence through the model")
	var m := rock_at(ImpactModel.ROCK_IN)
	check(near(m.image_scale, 1.28, 0.01), "image scale ~1.28 at rockIn (got %.4f)" % m.image_scale)
	m = rock_at(0.5)
	check(near(m.roll_deg, 8.5, 0.05), "roll ~8.5 deg at 0.5 s (got %.3f)" % m.roll_deg)
	check(near(m.image_scale, 1.28 - 0.28 * ImpactModel.smooth_unit((0.5 - 0.45) / 0.35), 0.01), "scale easing out after hold (%.4f)" % m.image_scale)
	m = rock_at(1.4)
	check(near(m.roll_deg, -7.0, 0.05), "roll ~-7 deg at 1.4 s (got %.3f)" % m.roll_deg)
	check(near(m.image_scale, 1.0, 1e-4), "scale back to 1 by 1.4 s")
	m = rock_at(2.45)
	check(near(m.roll_deg, 0.0, 0.01) and near(m.image_scale, 1.0, 1e-5) and m.blur == 0.0 and m.shift_x == 0.0 and m.shift_y == 0.0, "everything ~0 at 2.4+ s (roll %.4f)" % m.roll_deg)
	m = rock_at(2.6)
	check(not m.active() and m.mode == "none" and m.rock_focus == 0.0, "rock shot retired after its 2.5 s life")
	m = rock_at(0.0)
	check(m.blur > 0.9, "rock opens with the full .95 world blur (%.3f)" % m.blur)
	check(m.shift_y > 0.0 and m.shift_x < 0.0, "rock onset shifts image down and against the punch (y %.3f, x %.3f)" % [m.shift_y, m.shift_x])
	m = rock_at(0.1)
	check(absf(m.roll_deg) > 9.0, "kick roll > 9 deg near its 94 ms peak (%.2f)" % m.roll_deg)
	var mneg := rock_at(0.5, 1.0, -1.0)
	check(near(mneg.roll_deg, -8.5, 0.05), "mirrored punch direction mirrors the tilt")

	print("-- calmer non-rock hits")
	var rock_peak := 0.0
	var big_peak := 0.0
	var big_scale_max := 1.0
	var big_blur := 0.0
	var mr := ImpactModel.new()
	var mb := ImpactModel.new()
	mr.consume({"attacker": 0, "kind": "rock", "quality": 1.0, "dir_sign": 1.0})
	mb.consume({"attacker": 0, "kind": "big", "quality": 1.0, "dir_sign": 1.0})
	for i in 600:
		mr.step(1.0 / 240.0)
		mb.step(1.0 / 240.0)
		rock_peak = maxf(rock_peak, absf(mr.roll_deg))
		big_peak = maxf(big_peak, absf(mb.roll_deg))
		big_scale_max = maxf(big_scale_max, mb.image_scale)
		big_blur = maxf(big_blur, mb.blur)
	check(big_peak <= 3.01 and big_peak < rock_peak * 0.4, "heavy non-rock peak roll %.2f is far calmer than rock %.2f" % [big_peak, rock_peak])
	check(big_scale_max <= 1.0 + 1e-6 and big_blur == 0.0, "heavy non-rock has no push-in and no blur")
	var cue := ImpactModel.cue_for_hit({"zone": "head", "blocked": false, "strength": "heavy", "counter": false, "quality": 1.0, "rocked": false})
	check(cue["kind"] == "big" and cue["sweat"] == 18 and cue["spit"] == 3, "heavy head hit maps to big cue (18 sweat / 3 spit)")
	cue = ImpactModel.cue_for_hit({"zone": "head", "blocked": false, "strength": "heavy", "counter": true, "quality": 1.0, "rocked": true})
	check(cue["kind"] == "rock" and cue["sweat"] == 22 and cue["spit"] == 4, "rocking counter maps to rock cue (22 sweat / 4 spit, counter wins as on the web)")
	cue = ImpactModel.cue_for_hit({"zone": "head", "blocked": false, "strength": "heavy", "counter": false, "quality": 1.0, "rocked": true})
	check(cue["kind"] == "rock" and cue["sweat"] == 26 and cue["spit"] == 4, "rocking head hit maps to rock cue (26 sweat / 4 spit)")
	cue = ImpactModel.cue_for_hit({"zone": "head", "blocked": true, "strength": "heavy"})
	check(cue["kind"] == "none" and cue["sweat"] == 0, "blocked hit has no camera shot and no spray")
	cue = ImpactModel.cue_for_hit({"zone": "body", "blocked": false, "strength": "heavy", "quality": 1.0})
	check(cue["sweat"] == 0, "body hit sprays nothing")

	print("-- duplicate rock + release")
	var d := ImpactModel.new()
	check(d.consume({"attacker": 0, "kind": "rock", "dir_sign": 1.0}), "first rock accepted")
	d.step(0.05)
	check(not d.consume({"attacker": 0, "kind": "rock", "dir_sign": 1.0}), "state-change duplicate of the same rock is dropped")
	d.step(0.5)
	d.release()
	for i in 14:
		d.step(1.0 / 30.0)
	check(not d.active() and d.image_scale == 1.0 and d.roll_deg == 0.0, "release() fades the effect out within 0.4 s")
	var settle := ImpactModel.new()
	settle.consume({"attacker": 0, "kind": "rock", "dir_sign": 1.0})
	for i in 900:
		settle.step(1.0 / 120.0)
	check(not settle.active() and settle.image_scale == 1.0 and settle.roll_deg == 0.0 and settle.blur == 0.0, "effects decay to exactly zero after 7.5 s")
	settle.step(0.0)
	settle.step(NAN)
	settle.step(-1.0)
	check(settle.image_scale == 1.0, "zero / NaN / negative dt are ignored")

	print("-- camera integration (stub match)")
	var sm: Node = StubMatch.instantiate()
	root.add_child(sm)
	var a := Node3D.new()
	var b := Node3D.new()
	root.add_child(a)
	root.add_child(b)
	a.global_position = Vector3(-0.5, 0, 0)
	b.global_position = Vector3(0.5, 0, 0)
	var cam := FightCamera.new()
	root.add_child(cam)
	cam.track(a, b)
	cam.bind_match(sm)
	await process_frame
	await process_frame
	var base_fov := cam.fov
	sm.hit_landed.emit(0, {"zone": "head", "blocked": false, "damage": 12.0, "strength": "heavy", "position": Vector3(0.5, 1.5, 0), "counter": false, "strike": "RHook", "quality": 1.0, "rocked": true, "knockdown": false})
	sm.fighter_state_changed.emit(1, "rocked")
	check(cam.impact.impulses.size() == 1, "hit_landed + fighter_state_changed rocked start ONE rock sequence")
	var min_fov := 999.0
	var max_roll := 0.0
	var frames := 0
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 900:
		await process_frame
		frames += 1
		min_fov = minf(min_fov, cam.fov)
		max_roll = maxf(max_roll, absf(cam.impact.roll_deg))
	check(min_fov < base_fov - 5.0, "camera fov narrows during the push-in (%.1f -> %.1f)" % [base_fov, min_fov])
	check(max_roll > 5.0, "camera rolls during the rock (%.1f deg over %d frames)" % [max_roll, frames])
	# rocked state alone (no hit_landed) also plays the sequence
	sm.fighter_state_changed.emit(0, "rocked")
	check(cam.impact.impulses.size() >= 1 and cam.impact.rock_phase != "none", "fighter_state_changed rocked alone starts a rock")
	# pause mid-effect
	paused = true
	await process_frame
	await process_frame
	check(not cam.post.rect.visible, "post pass hides while the tree is paused")
	paused = false
	await process_frame
	# KO mid-effect
	sm.hit_landed.emit(0, {"zone": "head", "blocked": false, "damage": 12.0, "strength": "heavy", "position": Vector3(0.5, 1.5, 0), "quality": 1.0, "rocked": true})
	await process_frame
	sm.match_ended.emit({"method": "KO", "winner": 0})
	var t1 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t1 < 800:
		await process_frame
	check(not cam.impact.active() and near(cam.impact.image_scale, 1.0, 1e-5), "KO mid-rock releases the effect cleanly")
	# non-KO match end mid-effect, then free everything
	sm.match_ended.emit({"method": "Decision", "winner": 0})
	sm.hit_landed.emit(1, {"zone": "head", "blocked": false, "damage": 12.0, "strength": "heavy", "position": Vector3(-0.5, 1.5, 0), "quality": 1.0, "rocked": true})
	await process_frame
	cam.queue_free()
	sm.queue_free()
	await process_frame
	await process_frame
	check(true, "freeing camera and match mid-effect does not error")

	print("PASS" if failures == 0 else "FAIL (%d)" % failures)
	quit(0 if failures == 0 else 1)
