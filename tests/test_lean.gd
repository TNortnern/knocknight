extends SceneTree
# Analog lean: head travel + return, hurtbox follows (jab misses), punches thrown from a lean keep it, slip-counter flag,
# layered reaction while leaning, duck pose (neck / gloves, also rocked + gassed), footwork acceleration.
# godot --headless --path . --fixed-fps 120 --script res://tests/test_lean.gd

var failures := 0
var m: Match
var hits: Array = []
var whiffs: Array = []


func check(ok: bool, msg: String) -> void:
	if ok:
		print("  ok   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1


func steps(n: int) -> void:
	for i in n:
		await physics_frame


func make_match() -> void:
	if m != null:
		get_root().remove_child(m)
		m.queue_free()
		await process_frame
	hits.clear()
	whiffs.clear()
	m = load("res://scenes/match.tscn").instantiate()
	m.setup({"intro_delay": 0.0, "mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy", "rounds": 1, "round_seconds": 120.0})
	m.hit_landed.connect(func(i, info): hits.append({"i": i, "info": info}))
	m.whiffed.connect(func(i, s): whiffs.append({"i": i, "strike": s}))
	get_root().add_child(m)
	await process_frame


func duel(gap: float) -> Array:
	await make_match()
	var f: Array = m.get_fighters()
	f[0].global_position = Vector3(-gap * 0.5, 0, 0)
	f[1].global_position = Vector3(gap * 0.5, 0, 0)
	f[0].external_input = FighterInput.new()
	f[1].external_input = FighterInput.new()
	await steps(90)
	return f


func throw(fighter: Fighter, tag: String) -> void:
	fighter.external_input.strikes.append(tag)
	await steps(1)
	fighter.external_input.strikes.clear()


var _att := {}


## Final (post modifier) bone position: Skeleton3D.get_bone_global_pose does not show the modifiers' result outside the callback,
## BoneAttachment3D does (it is what the hurtboxes ride on).
func bone_p(fi: Fighter, bone: String) -> Vector3:
	var key := "%d_%s" % [fi.get_instance_id(), bone]
	if not _att.has(key):
		var ba := BoneAttachment3D.new()
		ba.bone_name = bone
		fi.rig.skeleton.add_child(ba)
		_att[key] = ba
	var p: Vector3 = (_att[key] as BoneAttachment3D).global_position
	var d := p - fi.global_position
	return Vector3(d.dot(fi.global_basis.x), d.y, d.dot(fi.global_basis.z))   # x = fighter's left, y up, z towards the foe


func head_pos(fi: Fighter) -> Vector3:
	var p := Vector3.ZERO
	for hu in fi.rig.hurtboxes:
		if hu.zone == "head":
			p = hu.shape_node.global_position
	var d := p - fi.global_position
	return Vector3(d.dot(fi.global_basis.x), d.y, d.dot(fi.global_basis.z))


func head_hits() -> int:
	return hits.filter(func(h): return h["info"]["zone"] == "head" and not h["info"]["blocked"] and h["i"] == 0).size()


func neck_rel_deg(fi: Fighter) -> Vector2:
	# neck direction in the spine's own frame: pitch = forward tilt, roll = tilt to the fighter's left
	var u := (bone_p(fi, "chestUpper") - bone_p(fi, "abdomenLower")).normalized()
	var l := (Vector3.RIGHT - u * u.dot(Vector3.RIGHT)).normalized()
	var fw := l.cross(u)
	var nk := bone_p(fi, "head") - bone_p(fi, "neckLower")
	return Vector2(rad_to_deg(atan2(nk.dot(fw), nk.dot(u))), rad_to_deg(atan2(nk.dot(l), nk.dot(u))))


func gloves_ok(fi: Fighter) -> String:
	var h := bone_p(fi, "head")
	var worst := ""
	var in_front := false
	for g in ["lHand", "rHand"]:
		var r := bone_p(fi, g) - h
		if r.length() > 0.62:
			worst += " %s %.2f m from the head" % [g, r.length()]
		if r.z > 0.06 and absf(r.x) < 0.32 and r.y > -0.35 and r.y < 0.3:
			in_front = true
	if not in_front:
		worst += " no glove in front of the face"
	return worst


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("== A. analog lean: side leans move the head ~20 cm in 0.3 s, ease in, and come home on release")
	var f := await duel(1.4)
	var d: Fighter = f[1]
	var base := head_pos(d)
	for dir in [1, -1]:
		d.external_input.slip = dir
		var early := 0.0
		var at30 := 0.0
		var drop := 0.0
		base = head_pos(d)
		for i in 40:
			await physics_frame
			var h := head_pos(d)
			if i == 4:
				early = absf(h.x - base.x)
			if i == 35:
				at30 = absf(h.x - base.x)
				drop = base.y - h.y
		print("       dir %d: %.0f cm sideways at 0.3 s (%.0f cm at 0.04 s), head drop %.0f cm" % [dir, at30 * 100.0, early * 100.0, drop * 100.0])
		check(at30 >= 0.20 and at30 <= 0.48, "head travels %.0f cm to the side (20..48)" % (at30 * 100.0))
		check(early < at30 * 0.35, "eased in: only %.0f cm after 0.04 s (< 35%% of the final)" % (early * 100.0))
		check(drop >= 0.04, "head also sinks %.0f cm (waist + knees)" % (drop * 100.0))
		check(d.state == Fighter.State.SLIP, "lean state while held (%s)" % d.state_name)
		d.external_input.slip = 0
		await steps(36)   # 0.3 s
		var back := absf(head_pos(d).x - base.x)
		check(back < 0.06 and d.lean_pose.pos.length() < 0.05, "released: back within 6 cm (idle sway included) after 0.3 s (%.1f cm)" % (back * 100.0))
		await steps(24)
		check(d.state == Fighter.State.IDLE, "back to idle (%s)" % d.state_name)
	print("== A2. lean modifier + move stick leans back (analog), feet stay planted")
	var away := -d.dir_to_foe()
	base = head_pos(d)
	d.external_input.lean_mod = true
	d.external_input.move = Vector2(away.x, -away.z)
	var p0 := d.global_position
	await steps(40)
	var hb := head_pos(d)
	check(base.z - hb.z >= 0.15, "head moves back %.0f cm (>= 15)" % ((base.z - hb.z) * 100.0))
	check(d.lean_pose.pos.y < -0.8, "lean y = %.2f (back)" % d.lean_pose.pos.y)
	check(d.global_position.distance_to(p0) < 0.06, "feet stayed planted (%.1f cm)" % (d.global_position.distance_to(p0) * 100.0))
	d.external_input.lean_mod = false
	d.external_input.move = Vector2.ZERO
	await steps(60)

	print("== B. hurtbox follows the lean: a jab at the head misses a full side lean and a lean back")
	var land_ctrl := 0
	for tag in ["LJab", "RJab"]:
		f = await duel(0.90)
		await throw(f[0], tag)
		await steps(110)
		land_ctrl += head_hits()
	check(land_ctrl >= 1, "control: unleaned head gets hit by the jabs (%d/2)" % land_ctrl)
	var miss := 0
	var tried := 0
	for setup in ["left", "right", "back"]:
		for tag in ["LJab", "RJab"]:
			f = await duel(0.90)
			var i2: FighterInput = f[1].external_input
			match setup:
				"left": i2.slip = 1
				"right": i2.slip = -1
				"back": i2.lean = Vector2(0, -1)
			await steps(40)
			await throw(f[0], tag)
			await steps(110)
			tried += 1
			var hh := head_hits()
			print("       lean %s vs %s -> head hits %d" % [setup, tag, hh])
			if hh == 0:
				miss += 1
	check(miss >= 4, "full leans make the jabs miss (%d/%d)" % [miss, tried])

	print("== C. a punch thrown from the lean keeps the lean; slip then counter gets the counter bonus")
	f = await duel(0.90)
	d = f[1]
	d.external_input.slip = 1
	await steps(40)
	var lean0: float = d.lean_pose.pos.length()
	await throw(d, "RHook")
	var kept := 0
	var seen_attack := 0
	for i in 40:
		await physics_frame
		if d.state == Fighter.State.ATTACK:
			seen_attack += 1
			if d.lean_pose.pos.length() > 0.7:
				kept += 1
	check(seen_attack > 10 and kept >= seen_attack - 2, "lean held through the hook (%d/%d ticks, lean %.2f -> %.2f)" % [kept, seen_attack, lean0, d.lean_pose.pos.length()])
	f = await duel(0.90)
	var att: Fighter = f[0]
	d = f[1]
	d.external_input.slip = 1
	await steps(30)
	await throw(att, "LJab")
	var waited := 0
	while d.counter_window <= 0.0 and waited < 150:
		await physics_frame
		waited += 1
	await throw(d, "RHook")
	await steps(2)
	check(bool(d.atk.get("counter", false)), "counter flag set on the strike thrown from the slip")
	hits.clear()
	await steps(110)
	var ch := hits.filter(func(h): return h["i"] == 1)
	if ch.size() >= 1 and bool(ch[0]["info"]["blocked"]):
		check(ch[0]["info"]["counter"] == false, "a counter caught on the guard carries no bonus (blocked: the rule)")
	elif ch.size() >= 1:
		check(ch[0]["info"]["counter"] == true, "landed counter carries the bonus (hit %d)" % ch.size())
	else:
		print("       (counter hook did not land from this spacing; flag verified above)")

	print("== D. hit while leaning: layered reaction, no snap to the base animation")
	f = await duel(0.90)
	att = f[0]
	d = f[1]
	d.external_input.lean = Vector2(0.3, 0.0)   # a small lean: the jab still lands
	await steps(40)
	var k0: int = d._hit_flinch.kicks
	await throw(att, "LJab")
	var got := 0
	var state_ok := true
	var lean_at_hit := 0.0
	for i in 110:
		await physics_frame
		if got == 0 and hits.size() > 0:
			got = 1
			lean_at_hit = d.lean_pose.pos.length()
			await steps(12)
			state_ok = d.state == Fighter.State.SLIP
	check(got == 1, "the jab landed on the leaning fighter (hits %d)" % hits.size())
	check(d._hit_flinch.kicks > k0, "flinch layer kicked (%d -> %d)" % [k0, d._hit_flinch.kicks])
	check(state_ok, "state stayed lean (%s), no snap to idle / hit clip" % d.state_name)
	check(lean_at_hit > 0.15, "lean still on (%.2f) when the hit landed" % lean_at_hit)
	var sg := []
	for lx in [0.0, 1.0]:
		f = await duel(0.90)
		att = f[0]
		d = f[1]
		d.external_input.lean = Vector2(lx, 0.0)
		await steps(40)
		var peak := 0.0
		await throw(att, "RHook")
		for i in 60:
			await physics_frame
			peak = maxf(peak, d._hit_flinch.head.length())
		sg.append(peak)
	print("       head flinch peak: no lean %.2f, leaning into the hook %.2f" % [sg[0], sg[1]])

	print("== E. duck pose: neck in line with the spine, gloves in front of the face, also rocked + gassed")
	f = await duel(0.90)
	var rest_ref := neck_rel_deg(f[1])
	print("       idle neck vs spine (pitch, roll deg): %s" % rest_ref)
	for variant in ["fresh", "rocked", "gassed", "both"]:
		f = await duel(0.90)
		d = f[1]
		if variant in ["gassed", "both"]:
			d.stats.stamina = d.stats.stamina_max * 0.04
		if variant in ["rocked", "both"]:
			d._begin_head_hurt(f[0], StrikeDB.get_strike("RHook"), 0.8, "F")
		await steps(30)
		d.external_input.duck = true
		var worst := Vector2.ZERO
		var gl := ""
		for i in 70:
			await physics_frame
			if i > 30:
				var nr := neck_rel_deg(d) - rest_ref
				if absf(nr.x) > absf(worst.x):
					worst.x = nr.x
				if absf(nr.y) > absf(worst.y):
					worst.y = nr.y
				var g := gloves_ok(d)
				if g != "":
					gl = g
		print("       %s: neck vs spine pitch %.0f deg, roll %.0f deg%s" % [variant, worst.x, worst.y, (" | gloves:" + gl) if gl != "" else ""])
		check(d.state == Fighter.State.CROUCH, "%s: ducking (%s)" % [variant, d.state_name])
		check(worst.x < 42.0 and worst.x > -55.0 and absf(worst.y) < 32.0, "%s: neck within a natural range of the spine" % variant)
		check(gl == "", "%s: gloves stay in front of the face%s" % [variant, gl])

	print("== F. footwork accelerates over >= 0.1 s, no instant start")
	f = await duel(3.0)
	d = f[1]
	var dir_away: Vector3 = -d.dir_to_foe()
	d.external_input.move = Vector2(dir_away.x, -dir_away.z)
	var speeds := []
	for i in 48:
		await physics_frame
		speeds.append(Vector2(d.velocity.x, d.velocity.z).length())
	var vmax: float = speeds.max()
	var t90 := 0.0
	for i in speeds.size():
		if speeds[i] >= 0.9 * vmax:
			t90 = float(i + 1) / 120.0
			break
	print("       v at 0.025 s %.2f, 0.05 s %.2f, 0.1 s %.2f, max %.2f m/s, 90%% at %.3f s" % [speeds[2], speeds[5], speeds[11], vmax, t90])
	check(speeds[2] < 0.2 * vmax, "no instant start (%.2f m/s after 0.025 s)" % speeds[2])
	check(t90 >= 0.10 and t90 <= 0.30, "ease-in to 90 %% speed takes %.2f s (0.10..0.30)" % t90)

	print("== G. tap = flick slip (auto timed, returns by itself); hold = analog lean")
	f = await duel(1.4)
	d = f[1]
	base = head_pos(d)
	d.external_input.slip = 1
	await steps(8)   # 0.07 s tap
	d.external_input.slip = 0
	var peak := 0.0
	var t_peak := 0.0
	var idle_at := -1.0
	for i in 120:
		await physics_frame
		var dx := absf(head_pos(d).x - base.x)
		if dx > peak:
			peak = dx
			t_peak = float(i + 8) / 120.0
		if idle_at < 0.0 and d.state == Fighter.State.IDLE:
			idle_at = float(i + 8) / 120.0
	print("       tap: peak %.0f cm at %.2f s, back to idle at %.2f s" % [peak * 100.0, t_peak, idle_at])
	# Fight Night quick slip: even a 0.07 s tap slips a clear 12+ cm, the head peaks about 0.1 s in and the let-go spring brings it home by ~0.35 s
	# (was: peak 0.2-0.5 s, idle 0.5-0.85 s - the slow creep this spec replaces)
	check(peak >= 0.12, "a 0.07 s tap still slips clearly (%.0f cm)" % (peak * 100.0))
	check(t_peak >= 0.04 and t_peak <= 0.25, "peak %.2f s after the tap started" % t_peak)
	check(idle_at > 0.15 and idle_at < 0.5, "auto-return, idle after %.2f s" % idle_at)
	d.external_input.slip = 1
	await steps(60)
	check(d.lean_pose.pos.x > 0.9 and d.state == Fighter.State.SLIP, "holding keeps the lean (%.2f)" % d.lean_pose.pos.x)
	d.external_input.slip = 0

	if failures == 0:
		print("PASS: lean")
		quit(0)
	else:
		print("FAIL: %d check(s) failed" % failures)
		quit(1)
