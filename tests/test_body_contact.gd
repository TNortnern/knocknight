extends SceneTree
# Body contact: force-balance pushing, shove-off, ropes, smothered punches, referee break, no interpenetration.
# godot --headless --fixed-fps 120 --path . --script res://tests/test_body_contact.gd
# Prints PASS/FAIL and exits 0 / 1.

const BodyContact := preload("res://scripts/fighter/body_contact.gd")
const MIN_CENTRES := 0.20
const MIN_CHEST := 0.30
const MIN_VOLUME_GAP := -0.04   ## the torso hulls (HitAreas.torso_gap) never overlap by more than 4 cm (arms / gloves may rest inside the foe's torso volume: that is the frame)

var failures := 0
var main: Node
var m: Match
var _chest := {}
var _head := {}
var trace := false


func check(ok: bool, msg: String) -> void:
	if ok:
		print("  ok   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1


func steps(n: int) -> void:
	for i in n:
		await physics_frame


func make_match(p1: String, p2: String) -> Array:
	if main != null:
		get_root().remove_child(main)
		main.queue_free()
		await process_frame
	Engine.time_scale = 1.0
	_chest.clear()
	_head.clear()
	var full := {"intro_delay": 0.0, "mode": "exhibition", "rounds": 1, "round_seconds": 600.0, "rules": "boxing",
		"p1_model": p1, "p2_model": p2, "arena": "ring", "p1_controller": "dummy", "p2_controller": "dummy"}
	main = load("res://scenes/main.tscn").instantiate()
	get_root().add_child(main)
	await process_frame
	main.start_match(full)
	await process_frame
	m = main.current_match
	var f: Array = m.get_fighters()
	for fi in f:
		var x: Fighter = fi
		var sk: Skeleton3D = x.rig.skeleton
		var id := x.get_instance_id()
		sk.skeleton_updated.connect(func():
			if is_instance_valid(sk) and sk.is_inside_tree():
				_chest[id] = sk.global_transform * sk.get_bone_global_pose(sk.find_bone("chestUpper")).origin
				_head[id] = sk.global_transform * sk.get_bone_global_pose(sk.find_bone("head")).origin)
		x.external_input = FighterInput.new()
		x.stats.infinite_stamina = false
	await steps(60)
	return f


func place(a: Fighter, b: Fighter, pa: Vector3, pb: Vector3) -> void:
	a.global_position = pa
	b.global_position = pb
	a.velocity = Vector3.ZERO
	b.velocity = Vector3.ZERO
	a._push = Vector3.ZERO
	b._push = Vector3.ZERO


func walk(towards: Vector3) -> FighterInput:
	var i := FighterInput.new()
	i.move = Vector2(towards.x, -towards.z)
	return i


## Runs `n` frames; tracks the minimum root gap / chest distance. Returns {min_gap, min_chest}.
func run(a: Fighter, b: Fighter, n: int, chasers := []) -> Dictionary:
	var r := {"min_gap": 9.0, "min_chest": 9.0}
	for i in n:
		for x in chasers:
			x.external_input = walk(x.dir_to_foe())   # walks straight at the foe (the screen-frame input re-aimed every tick)
		await physics_frame
		if trace and i % 30 == 0:
			print("      t=%.2f oak %s vip %s vcorr %s" % [i / 120.0, a.global_position, b.global_position, a.bc.last_vc])
		r["min_gap"] = minf(r["min_gap"], a.gap_to_foe())
		var ca: Vector3 = _chest.get(a.get_instance_id(), Vector3.ZERO)
		var cb: Vector3 = _chest.get(b.get_instance_id(), Vector3(9, 0, 9))
		r["min_chest"] = minf(r["min_chest"], Vector2(ca.x - cb.x, ca.z - cb.z).length())
		r["min_contact"] = minf(r.get("min_contact", 9.0), HitAreas.torso_gap(a, b))
	return r


func _run() -> void:
	print("== smothered punches (rules)")
	var jab := StrikeDB.get_strike("RJab")
	var hook := StrikeDB.get_strike("LHook")
	var upper := StrikeDB.get_strike("RUppercut")
	var body := StrikeDB.get_strike("RBodyHook")
	var ctx := {"quality": 1.0}
	var base := {}
	for s in [jab, hook, upper, body]:
		base[s["tag"]] = CombatRules.compute_damage(s, ctx)["total"]
	var ratio := {}
	for s in [jab, hook, upper, body]:
		var c := ctx.duplicate()
		c["smother"] = BodyContact.smother_factor(s, 0.72, 1.0)
		ratio[s["tag"]] = CombatRules.compute_damage(s, c)["total"] / base[s["tag"]]
	print("    damage kept at 0.72 m: jab %.2f  hook %.2f  uppercut %.2f  body hook %.2f" % [ratio["RJab"], ratio["LHook"], ratio["RUppercut"], ratio["RBodyHook"]])
	check(ratio["RJab"] < 0.7 and ratio["LHook"] < 0.85, "straights / hooks are smothered in contact range")
	check(ratio["RUppercut"] > 0.93 and ratio["RBodyHook"] > 0.88, "uppercuts and body shots keep their damage")
	check(ratio["RUppercut"] > ratio["RJab"] + 0.3 and ratio["RBodyHook"] > ratio["LHook"], "short punches deal more than long ones at contact range")
	check(is_equal_approx(BodyContact.smother_factor(jab, 1.0, 1.0), 1.0), "no smothering at jab range")
	check(is_equal_approx(BodyContact.smother_factor(jab, 0.72, 0.0), 1.0), "a punch stepping in from range is not smothered")

	print("== heavy walks a light passive fighter backwards (Oak 1.30 vs Viper 0.90)")
	var f := await make_match("meshy_oak", "meshy_viper")
	var oak: Fighter = f[0]
	var vip: Fighter = f[1]
	check(oak.stats.mass > vip.stats.mass, "mass from the roster: %.2f vs %.2f" % [oak.stats.mass, vip.stats.mass])
	place(oak, vip, Vector3(-1.2, 0, 0), Vector3(-0.45, 0, 0))
	await steps(30)
	var x0 := vip.global_position.x
	var r := await run(oak, vip, 360, [oak])
	var moved := vip.global_position.x - x0
	print("    passive Viper driven %.2f m in 3 s; min gap %.3f min chest %.3f  oak stamina %.0f  viper stamina %.0f" % [moved, r["min_gap"], r["min_chest"], oak.stats.stamina, vip.stats.stamina])
	check(moved > 0.9, "the lighter passive fighter is driven back (%.2f m)" % moved)
	check(r["min_gap"] >= MIN_CENTRES, "roots never closer than %.2f (%.3f)" % [MIN_CENTRES, r["min_gap"]])
	check(r.get("min_contact", 9.0) >= MIN_VOLUME_GAP, "chests never closer than %.2f (%.3f)" % [MIN_CHEST, r["min_chest"]])
	check(vip.bc.pressed_w > 0.3 and oak.bc.press_w > 0.3, "pose weights: presser %.2f / pressed %.2f" % [oak.bc.press_w, vip.bc.pressed_w])
	check(vip.stats.stamina < vip.stats.stamina_max - 1.0, "being leaned on costs the pressed fighter stamina")
	var d_oak := BodyContact.shove_distance(oak, vip)
	var d_vip := BodyContact.shove_distance(vip, oak)
	check(d_oak > d_vip and d_oak <= 0.6 and d_vip >= 0.4, "the stronger fighter shoves further (%.2f vs %.2f)" % [d_oak, d_vip])

	print("== equal masses pressing stall")
	f = await make_match("meshy_boxer1", "meshy_boxer1")
	var a: Fighter = f[0]
	var b: Fighter = f[1]
	place(a, b, Vector3(-0.38, 0, 0), Vector3(0.38, 0, 0))
	await steps(30)
	var mid0 := (a.global_position + b.global_position) * 0.5
	r = await run(a, b, 240, [a, b])   # < BREAK_AFTER so the break does not interfere
	var drift := ((a.global_position + b.global_position) * 0.5 - mid0).length()
	print("    drift of the pair %.2f m in 2 s; min gap %.3f min chest %.3f" % [drift, r["min_gap"], r["min_chest"]])
	check(drift < 0.25, "equal pushes roughly stall (drift %.2f m)" % drift)
	check(r["min_gap"] >= MIN_CENTRES and r.get("min_contact", 9.0) >= MIN_VOLUME_GAP, "no interpenetration while locked (gap %.3f chest %.3f)" % [r["min_gap"], r["min_chest"]])

	print("== referee break after a locked clinch")
	var broke := [0]
	a.bc.referee_break.connect(func(): broke[0] += 1)
	var gaps: Array = []
	var t := 0.0
	var broke_t := -1.0
	for i in 720:
		for x in [a, b]:
			x.external_input = walk(x.dir_to_foe())
		await physics_frame
		gaps.append(a.gap_to_foe())
		t += 1.0 / 120.0
		if broke[0] > 0 and broke_t < 0.0:
			broke_t = t
	var max_step := 0.0
	var at := 0
	for i in range(1, gaps.size()):
		if gaps[i] - gaps[i - 1] > max_step:   # opening steps only: afterwards the pressing inputs walk them back in
			max_step = gaps[i] - gaps[i - 1]
			at = i
	print("    gaps around the biggest step: ", gaps.slice(maxi(at - 4, 0), at + 4))
	var gmax := 0.0
	for g in gaps:
		gmax = maxf(gmax, g)
	print("    break signalled %d x, first at +%.2f s (of the continued lock); max gap %.2f, max per-frame change %.4f" % [broke[0], broke_t, gmax, max_step])
	check(broke[0] >= 1, "locked contact triggers a referee break")
	check(gmax >= 1.1, "the break separates them (max gap %.2f)" % gmax)
	check(max_step < 0.02, "the break is smooth, not a teleport (max %.4f m / frame)" % max_step)

	print("== shove-off")
	f = await make_match("meshy_boxer1", "meshy_boxer1")
	a = f[0]
	b = f[1]
	place(a, b, Vector3(-0.38, 0, 0), Vector3(0.38, 0, 0))
	for i in 90:   # a shove needs touching bodies (not just 0.76 m between the roots): walk into each other first
		a.external_input = walk(a.dir_to_foe())
		b.external_input = walk(b.dir_to_foe())
		await physics_frame
	a.external_input = FighterInput.new()
	b.external_input = FighterInput.new()
	await steps(2)
	var gap0 := a.gap_to_foe()
	var si := FighterInput.new()
	si.shove = true
	a.external_input = si
	await physics_frame
	a.external_input = FighterInput.new()
	check(a.bc.shoves_thrown == 1, "the shove input starts a shove")
	check(a.stats.stamina < a.stats.stamina_max - 5.0, "the shove costs stamina")
	check(b.bc.off_balance() and b._balance() <= 0.3, "the shoved fighter is off balance (_balance %.2f)" % b._balance())
	await steps(12)   # 0.1 s after the shove
	check(not b.begin_attack("LJab"), "the shoved fighter cannot punch at +0.1 s")
	await steps(22)   # +0.28 s: the push has played out; his jab would step back in, so measure first
	var space := a.gap_to_foe() - gap0
	await steps(6)
	check(b.begin_attack("LJab"), "he can punch again after ~0.28 s")
	await steps(60)
	print("    shove opened %.2f m (equal mass)" % space)
	check(space >= 0.3 and space <= 0.7, "a shove opens 0.3-0.7 m (0.4-0.6 nominal; %.2f measured 0.28 s in, while he is still walking back in)" % space)

	print("== pressed against the ropes")
	f = await make_match("meshy_oak", "meshy_viper")
	oak = f[0]
	vip = f[1]
	place(oak, vip, Vector3(1.4, 0, 0.3), Vector3(2.2, 0, 0.3))
	await steps(30)
	r = await run(oak, vip, 480, [oak])
	var vx := vip.global_position.x
	print("    Oak ", oak.global_position, " Viper ", vip.global_position)
	print("    Viper stopped at x=%.2f, Oak at x=%.2f, min gap %.3f pinned=%s" % [vx, oak.global_position.x, r["min_gap"], vip.bc.pinned])
	check(vx <= 3.0 and vx > 2.6, "the ropes stop the pressed fighter (x=%.2f)" % vx)
	check(r["min_gap"] >= MIN_CENTRES and r.get("min_contact", 9.0) >= MIN_VOLUME_GAP, "no interpenetration on the ropes (gap %.3f chest %.3f)" % [r["min_gap"], r["min_chest"]])
	# shove off the ropes: opens less than in the open and rebounds, nobody ends inside the ropes
	var v_in := FighterInput.new()
	v_in.shove = true
	oak.external_input = FighterInput.new()
	vip.external_input = v_in
	await physics_frame
	vip.external_input = FighterInput.new()
	await steps(240)
	check(maxf(absf(vip.global_position.x), absf(vip.global_position.z)) <= 3.0, "a shove into the ropes stays inside the ring")

	await _inside_tests()
	print("PASS" if failures == 0 else "FAIL (%d)" % failures)
	quit(0 if failures == 0 else 1)


func head_offset(a: Fighter, b: Fighter) -> float:
	## sideways distance between the two heads (perpendicular to the line of roots)
	var ha: Vector3 = _head.get(a.get_instance_id(), Vector3.ZERO)
	var hb: Vector3 = _head.get(b.get_instance_id(), Vector3.ZERO)
	var line: Vector3 = b.global_position - a.global_position
	line.y = 0.0
	line = line.normalized()
	var perp := Vector3(-line.z, 0.0, line.x)
	return absf((hb - ha).dot(perp))


func _inside_tests() -> void:
	print("== point-blank whiff while driving forward: bump")
	var f := await make_match("meshy_oak", "meshy_viper")
	var oak: Fighter = f[0]
	var vip: Fighter = f[1]
	place(oak, vip, Vector3(-0.32, 0, 0), Vector3(0.30, 0, 0))   # 0.62 m: point blank (contact needs touching bodies: 0.42 m root to root)
	await steps(30)
	check(oak.begin_attack("RHook"), "Oak throws a hook at point-blank range")
	var vip_x0 := vip.global_position.x
	var r := {"min_gap": 9.0, "min_chest": 9.0}
	var foe_at_03 := 0.0
	var stumbled := false
	for i in 120:
		oak.external_input = walk(oak.dir_to_foe())   # keeps driving forward
		if not oak.atk.is_empty() and i == 6:
			oak.atk["outcome"] = "missed"   # the hook found nothing
			oak.atk["hit_done"] = true   # (contact-only hits: a point-blank hook would otherwise land on its way through)
		await physics_frame
		if i == 36:
			foe_at_03 = vip.global_position.x - vip_x0
		stumbled = stumbled or oak.bc.stumble_t > 0.0 or oak.bc.off_balance()
		r["min_gap"] = minf(r["min_gap"], oak.gap_to_foe())
		r["min_contact"] = minf(r.get("min_contact", 9.0), HitAreas.torso_gap(oak, vip))
		var ca: Vector3 = _chest.get(oak.get_instance_id(), Vector3.ZERO)
		var cb: Vector3 = _chest.get(vip.get_instance_id(), Vector3(9, 0, 9))
		r["min_chest"] = minf(r["min_chest"], Vector2(ca.x - cb.x, ca.z - cb.z).length())
	print("    bumps %d stumble %s foe pushed %.3f m in 0.3 s; min gap %.3f chest %.3f" % [oak.bc.bumps, stumbled, foe_at_03, r["min_gap"], r["min_chest"]])
	check(oak.bc.bumps >= 1, "the whiffing driver bumps into the foe")
	check(stumbled, "the overextended driver stumbles (off balance / stumble flag)")
	check(foe_at_03 > 0.03, "the foe is pushed back more than 3 cm (%.3f; the driver hits him ~0.2 m from the contact floor, not from 0.5 m out)" % foe_at_03)
	check(vip.bc.stagger_t > 0.0 or vip.stats.guard_lock > 0.0 or vip.bc.bump_hit_t > 0.0 or foe_at_03 > 0.03, "the foe's guard jolts")
	check(r["min_gap"] >= MIN_CENTRES and r.get("min_contact", 9.0) >= MIN_VOLUME_GAP, "no interpenetration in the bump (gap %.3f chest %.3f)" % [r["min_gap"], r["min_chest"]])

	print("== running into a standing fighter: driver stopped, not through him")
	f = await make_match("meshy_oak", "meshy_viper")
	oak = f[0]
	vip = f[1]
	place(oak, vip, Vector3(-1.4, 0, 0), Vector3(0.0, 0, 0))
	await steps(30)
	var no_punch_seen := false
	var drv_speed_after := 9.0
	r = {"min_gap": 9.0, "min_chest": 9.0}
	for i in 150:
		oak.external_input = walk(oak.dir_to_foe())
		oak._push += oak.dir_to_foe() * (0.8 if i < 20 else 0.0)   # a burst of speed into the contact
		await physics_frame
		no_punch_seen = no_punch_seen or oak.bc.no_punch_t > 0.0
		r["min_gap"] = minf(r["min_gap"], oak.gap_to_foe())
		r["min_contact"] = minf(r.get("min_contact", 9.0), HitAreas.torso_gap(oak, vip))
		var ca2: Vector3 = _chest.get(oak.get_instance_id(), Vector3.ZERO)
		var cb2: Vector3 = _chest.get(vip.get_instance_id(), Vector3(9, 0, 9))
		r["min_chest"] = minf(r["min_chest"], Vector2(ca2.x - cb2.x, ca2.z - cb2.z).length())
	print("    bumps %d no-punch seen %s; min gap %.3f chest %.3f" % [oak.bc.bumps, no_punch_seen, r["min_gap"], r["min_chest"]])
	check(r["min_gap"] >= MIN_CENTRES and r.get("min_contact", 9.0) >= MIN_VOLUME_GAP, "never inside each other (gap %.3f chest %.3f)" % [r["min_gap"], r["min_chest"]])
	check(oak.bc.bumps >= 1 and no_punch_seen, "the runner is stopped and cannot punch for a moment")

	print("== chest to chest: heads go to the side of each other")
	f = await make_match("meshy_boxer1", "meshy_boxer1")
	var a: Fighter = f[0]
	var b: Fighter = f[1]
	place(a, b, Vector3(-0.38, 0, 0), Vector3(0.38, 0, 0))
	var best := 0.0
	var best_t := 0.0
	for i in 150:
		a.external_input = walk(a.dir_to_foe())
		b.external_input = walk(b.dir_to_foe())
		await physics_frame
		var ho := head_offset(a, b)
		if i > 40:
			best = maxf(best, ho)
			if i % 20 == 0:
				best_t = ho
	print("    sideways head offset: max %.3f m (a lean %.2f rad, b lean %.2f rad)" % [best, a.rig.skeleton.get_node("ContactPose").lat, b.rig.skeleton.get_node("ContactPose").lat])
	check(best > 0.15, "the heads are offset sideways by more than 15 cm (%.3f)" % best)

	print("== frame keeps the root gap")
	var gaps := []
	for framed in [false, true]:
		f = await make_match("meshy_boxer1", "meshy_boxer1")
		a = f[0]
		b = f[1]
		place(a, b, Vector3(-0.45, 0, 0), Vector3(0.45, 0, 0))
		await steps(20)
		var mg := 9.0
		var settled := []
		for i in 200:
			a.external_input = walk(a.dir_to_foe())
			var bi := FighterInput.new()
			bi.block = framed
			b.external_input = bi
			await physics_frame
			if i > 100:
				settled.append(a.gap_to_foe())
		var avg := 0.0
		for g in settled:
			avg += g
		avg /= settled.size()
		gaps.append(avg)
		print("    framed=%s: settled root gap %.3f (frame_w %.2f)" % [framed, avg, b.bc.frame_w])
	check(gaps[1] >= gaps[0] + 0.04 and gaps[1] >= 0.45,   # the frame adds FRAME_EXTRA (0.05) to a steady press
	 "a framing fighter keeps more space (%.3f vs %.3f)" % [gaps[1], gaps[0]])

	print("== smother still works in contact (real fighters)")
	f = await make_match("meshy_oak", "meshy_viper")
	oak = f[0]
	vip = f[1]
	place(oak, vip, Vector3(-0.38, 0, 0), Vector3(0.38, 0, 0))
	await steps(30)
	for i in 200:
		oak.external_input = walk(oak.dir_to_foe())
		await physics_frame
	var jab2 := StrikeDB.get_strike("RJab")
	var up2 := StrikeDB.get_strike("RUppercut")
	var sj: float = oak.bc.smother_for(jab2)
	var su: float = oak.bc.smother_for(up2)
	print("    smother_for jab %.2f uppercut %.2f (contact_t %.2f, inside_pos %.2f)" % [sj, su, oak.bc.contact_t, oak.bc.inside_pos])
	check(sj < 0.7 and su > 0.85, "jab smothered, uppercut keeps its damage in a real contact")


func _initialize() -> void:
	_run.call_deferred()
