extends SceneTree
# Physics knockouts: PhysicalBone3D ragdoll build (both models), KO = simulation driven by a real punch, rest on the canvas,
# unique falls per punch, knockdown -> ragdoll -> get-up blend -> IDLE, the standing foe stays out of the body.
# godot --headless --fixed-fps 120 --path . --script res://tests/test_ragdoll.gd
# Prints PASS/FAIL and exits 0 / 1.

var failures := 0
const KO_SAMPLES := 2
var m: Match


func check(ok: bool, msg: String) -> void:
	if ok:
		print("  ok   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1


func steps(n: int) -> void:
	for i in n:
		Engine.time_scale = 1.0   # the KO's impact dip (ImpactFx.slowmo) is restored by a real-time timer: with it the number of game ticks per wall second, and so the rest pose, depended on how fast the machine was
		await physics_frame


func make_match(p1_model := "viper", p2_model := "anvil") -> Array:
	if m != null:
		get_root().remove_child(m)
		m.queue_free()
		await process_frame
	Engine.time_scale = 1.0
	m = load("res://scenes/match.tscn").instantiate()
	m.setup({"intro_delay": 0.0, "mode": "exhibition", "rounds": 1, "round_seconds": 600.0, "p1_controller": "dummy", "p2_controller": "dummy",
		"p1_model": p1_model, "p2_model": p2_model, "rules": "boxing"})
	get_root().add_child(m)
	await process_frame
	var f: Array = m.get_fighters()
	f[0].external_input = FighterInput.new()
	f[1].external_input = FighterInput.new()
	f[0].stats.infinite_stamina = true
	f[1].stats.infinite_stamina = true
	await steps(90)
	return f


func finite(v: Vector3) -> bool:
	return is_finite(v.x) and is_finite(v.y) and is_finite(v.z)


## All bodies of a ragdoll: {nan, ymin, ymax, vmax, wmax, maxdist}
func body_stats(rd) -> Dictionary:
	var out := {"nan": false, "ymin": 9.0, "ymax": -9.0, "vmax": 0.0, "wmax": 0.0, "maxdist": 0.0}
	var pel: Vector3 = rd.pelvis_position()
	for id in rd.bones:
		var pb: PhysicalBone3D = rd.bones[id]
		var p := pb.global_position
		if not finite(p) or not finite(pb.linear_velocity):
			out["nan"] = true
		out["ymin"] = minf(out["ymin"], p.y)
		out["ymax"] = maxf(out["ymax"], p.y)
		out["vmax"] = maxf(out["vmax"], pb.linear_velocity.length())
		out["wmax"] = maxf(out["wmax"], pb.angular_velocity.length())
		out["maxdist"] = maxf(out["maxdist"], p.distance_to(pel))
	return out


## Throws `tag` from P1 at P2 (head 0.4 + 3 knockdowns -> a TKO), waits for the fall, returns the rest summary.
func punch_ko(tag: String, gap: float, off: float) -> Dictionary:
	var f := await make_match()
	f[1]._ragdoll.rng_seed = 4000 + absi(tag.hash()) % 1000   # fixed per punch: the rest poses are reproducible
	var p1: Fighter = f[0]
	var p2: Fighter = f[1]
	p1.global_position = Vector3(-gap * 0.5, 0, off * 0.5)
	p2.global_position = Vector3(gap * 0.5, 0, -off * 0.5)
	await steps(60)
	var start := p2.global_position
	if tag.contains("Body"):
		p2.stats.body_max = 0.0
	else:
		p2.stats.head = 0.4
		p2.stats.knockdowns = 3
	p1.external_input.strikes.append(tag)
	await steps(1)
	p1.external_input.strikes.clear()
	var n := 0
	while p2.state != Fighter.State.DOWN and n < 600:
		await steps(1)
		n += 1
	var res := {"hit": p2.state == Fighter.State.DOWN, "sim": p2._ragdoll.active}
	await steps(2)
	res["capsule_off"] = (p2.get_node("CollisionShape3D") as CollisionShape3D).disabled
	var rest_n := 0
	while rest_n < 120 * 6 and not p2._ragdoll.settled(0.4):   # until at rest (at most 6 s: the rolling hook-R fall takes ~5-5.5 s)
		await steps(1)
		rest_n += 1
	var rd = p2._ragdoll
	res["stats"] = body_stats(rd)
	print("      %s: settled after %.2f s (vmax %.3f m/s)" % [tag, rest_n / 120.0, res["stats"]["vmax"]])
	res["bodies"] = rd.body_positions()
	res["head"] = rd.head_position()
	res["pelvis"] = rd.pelvis_position()
	res["start"] = start
	res["face_up"] = rd.lying_face_up()
	res["p1"] = p1.global_position
	res["pts"] = p2.body_points()
	return res


## Mean distance between the 17 bodies of two rests (world positions, both falls start from the same spot).
func pose_distance(a: Dictionary, b: Dictionary) -> float:
	var sum := 0.0
	var pa: Dictionary = a["bodies"]
	var pb: Dictionary = b["bodies"]
	for id in pa:
		sum += ((pa[id] as Vector3) - (a["start"] as Vector3)).distance_to((pb[id] as Vector3) - (b["start"] as Vector3))
	return sum / pa.size()


func seg_dist(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
	return p.distance_to(a + ab * t)


## Chest + pelvis front vectors of the resting body: "up" (face up), "down" (face down) or "side".
func lying_class(rd) -> String:
	var sum: float = 0.7 * (rd.bones["chest"] as PhysicalBone3D).global_basis.z.y + 0.3 * (rd.bones["pelvis"] as PhysicalBone3D).global_basis.z.y
	if sum > 0.3:
		return "up"
	if sum < -0.3:
		return "down"
	return "side"


## A scripted KO of `kind` (jab / straight / hookL / hookR / upper / over / body) from P1 on P2: the victim walks into the
## blow at `walk` m/s (towards the attacker), `seed_` seeds the fall's randomness. Returns {o, slide, lift_p, lift_f, settle}.
func scripted_ko(kind: String, seed_: int, walk: float) -> Dictionary:
	var f := await make_match()
	var p1: Fighter = f[0]
	var p2: Fighter = f[1]
	p1.global_position = Vector3(-0.4, 0, 0)
	p2.global_position = Vector3(0.4, 0, 0)
	await steps(30)
	var rd = p2._ragdoll
	rd.rng_seed = seed_
	var away := Vector3.RIGHT
	var lat := Vector3(away.z, 0.0, -away.x)
	var d := away
	var zone := "head"
	var prefix := "F"
	var limb := "R"
	match kind:
		"jab":
			limb = "L"
		"hookL":
			prefix = "L"
			d = (away * 0.55 - lat * 0.85).normalized()
			limb = "L"
		"hookR":
			prefix = "R"
			d = (away * 0.55 + lat * 0.85).normalized()
		"upper":
			prefix = "U"
			d = (away * 0.5 + Vector3.UP * 0.9).normalized()
		"over":
			prefix = "O"
			d = (away * 0.6 + Vector3.DOWN * 0.8).normalized()
		"body":
			zone = "body"
			d = (away + Vector3.DOWN * 0.2).normalized()
	var hp: Vector3 = rd.head_position() if zone == "head" else rd.pelvis_position()
	p2._last_hit = {"t": p2._time, "ev": {"position": hp, "speed": 4.5, "velocity": d * 4.5}, "strike": {"limb": limb}}
	for id in rd.bones:
		rd._lin_vel[id] = -away * walk   # the pose velocity the victim carries into the blow
	var start := p2.global_position
	p2._do_ko("tko", prefix, zone)
	await steps(1)
	var pel0: float = rd.pelvis_position().y
	var feet0: float = maxf(rd.bone_origin("lFoot").y, rd.bone_origin("rFoot").y)
	var lift_p := -9.0
	var lift_f := -9.0
	var settle := -1.0
	var n := 0
	var calm_n := 0
	while n < 120 * 4 and calm_n < 36:   # stop sampling 0.3 s after the body is calm
		await steps(1)
		n += 1
		calm_n = calm_n + 1 if settle >= 0.0 else 0
		lift_p = maxf(lift_p, rd.pelvis_position().y - pel0)
		for id in ["lFoot", "rFoot"]:
			lift_f = maxf(lift_f, (rd.bones[id] as PhysicalBone3D).global_position.y - feet0)
		if settle < 0.0 and rd.calm():
			settle = n / 120.0
	var pel: Vector3 = rd.pelvis_position()
	return {"o": lying_class(rd), "slide": Vector2(pel.x - start.x, pel.z - start.z).length(), "lift_p": lift_p, "lift_f": lift_f, "settle": settle, "stats": body_stats(rd)}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("== A. ragdoll builds for both models: bodies, masses, joints, limits")
	for pair in [["viper", "anvil"], ["anvil", "viper"]]:
		var f := await make_match(pair[0], pair[1])
		for i in 2:
			var fi: Fighter = f[i]
			var rd = fi._ragdoll
			check(rd.bones.size() == 17, "%s: 17 physical bodies (%d)" % [fi.model, rd.bones.size()])
			check(absf(rd.total_mass() - 81.2) < 0.6, "%s: total mass %.1f kg (~80)" % [fi.model, rd.total_mass()])
			check((rd.bones["head"] as PhysicalBone3D).mass == 5.0 and (rd.bones["chest"] as PhysicalBone3D).mass == 21.0 and (rd.bones["pelvis"] as PhysicalBone3D).mass == 11.5, "%s: head 5 / chest 21 / pelvis 11.5 kg" % fi.model)
			var types_ok := true
			for id in ["lForearm", "rForearm", "lShin", "rShin"]:
				types_ok = types_ok and (rd.bones[id] as PhysicalBone3D).joint_type == PhysicalBone3D.JOINT_TYPE_HINGE
			for id in ["lUpperArm", "rUpperArm", "lThigh", "rThigh", "neck", "head", "abdomen", "chest"]:
				types_ok = types_ok and (rd.bones[id] as PhysicalBone3D).joint_type == PhysicalBone3D.JOINT_TYPE_CONE
			check(types_ok, "%s: hinge elbows / knees, cone shoulders / hips / neck / spine" % fi.model)
			var kn: PhysicalBone3D = rd.bones["lShin"]
			var lo: float = kn.get("joint_constraints/angular_limit_lower")
			var hi: float = kn.get("joint_constraints/angular_limit_upper")
			check(hi > 100.0 and lo <= 0.0 and bool(kn.get("joint_constraints/angular_limit_enabled")), "%s: knee hinge limited (%.0f..%.0f deg)" % [fi.model, lo, hi])
			var hp: PhysicalBone3D = rd.bones["lThigh"]
			var sw: float = hp.get("joint_constraints/swing_span")
			var tw: float = hp.get("joint_constraints/twist_span")
			check(sw > 60.0 and tw > 10.0, "%s: hip cone limited (swing %.0f twist %.0f)" % [fi.model, sw, tw])
			var shapes_ok := true
			for id in rd.bones:
				var cs: CollisionShape3D = (rd.bones[id] as PhysicalBone3D).get_node("Shape")
				shapes_ok = shapes_ok and cs.shape != null
			check(shapes_ok, "%s: every body has a collision shape" % fi.model)
			var layers_ok := true
			for id in rd.bones:
				var pb: PhysicalBone3D = rd.bones[id]
				layers_ok = layers_ok and (pb.collision_mask & HitAreas.LAYER_BODY) == 0 and (pb.collision_layer & 0xFF) == 0 and (pb.collision_mask & HitAreas.LAYER_WORLD) != 0
			check(layers_ok, "%s: bodies collide with the world only, never a fighter capsule" % fi.model)

	print("== B. KO = simulation driven by the punch, at rest on the canvas")
	# contact-only hits: the scripted (unaimed) punches only touch from these ranges (was 0.75-0.85). The cross and the uppercut
	# are aimed (@aim): unaimed, whether they land or graze depends on where the foe's idle sway is when they are thrown
	var cases := [["LJab", "jab", 0.60, 0.0], ["RJab@aim", "cross", 0.60, 0.0], ["LHook", "hook L", 0.60, 0.0], ["RHook", "hook R", 0.60, 0.10],
		["RUppercut@aim", "uppercut", 0.50, 0.0], ["RBodyHook", "body hook", 0.70, 0.0]]
	var results := {}
	for c in cases:
		var r := await punch_ko(c[0], c[2], c[3])
		results[c[1]] = r
		var st: Dictionary = r["stats"]
		check(r["hit"] and r["sim"], "%s: KO started the simulation" % c[1])
		check(r["capsule_off"], "%s: body capsule switched off while ragdolling" % c[1])
		check(not st["nan"], "%s: no NaNs" % c[1])
		check(st["ymin"] > -0.05 and st["ymax"] < 0.6, "%s: at rest on the floor (body y %.3f .. %.3f)" % [c[1], st["ymin"], st["ymax"]])
		check(st["vmax"] < 0.3 and st["wmax"] < 2.0, "%s: velocities near zero (%.3f m/s, %.2f rad/s)" % [c[1], st["vmax"], st["wmax"]])
		check(st["maxdist"] < 3.0, "%s: no bone flying off (max %.2f m from the pelvis)" % [c[1], st["maxdist"]])
		var inside := 9.0
		var pts: Array = r["pts"]
		var p1: Vector3 = r["p1"]
		var me := Vector3(p1.x, 0, p1.z)
		for k in range(1, pts.size()):
			inside = minf(inside, seg_dist(me, pts[0], pts[k]))
		check(inside > 0.25, "%s: the standing foe is not inside the body (%.2f m from the nearest bone line)" % [c[1], inside])
	print("  rest head positions (x z) relative to the start:")
	var heads := {}
	for k in results:
		var r: Dictionary = results[k]
		var h: Vector3 = r["head"] - r["start"]
		heads[k] = Vector3(h.x, 0.0, h.z)
		print("    %-10s head (%.2f, %.2f)  pelvis moved %.2f m  face %s" % [k, h.x, h.z, (r["pelvis"] - r["start"]).length(), "up" if r["face_up"] else "down"])
	check(heads["hook L"].distance_to(heads["hook R"]) > 0.3, "hook L and hook R finish in different places (%.2f m apart)" % heads["hook L"].distance_to(heads["hook R"]))
	var keys := results.keys()
	var min_pair := 9.0
	var min_names := ""
	for i in keys.size():
		for j in range(i + 1, keys.size()):
			var d := pose_distance(results[keys[i]], results[keys[j]])
			if d < min_pair:
				min_pair = d
				min_names = "%s / %s" % [keys[i], keys[j]]
	check(min_pair > 0.2, "all six punches give distinct whole-body rest poses (closest pair %s: mean body distance %.2f m)" % [min_names, min_pair])

	print("== D. KO resting orientation follows the blow, the victim's momentum and the dice (not always face up)")
	var kinds := ["jab", "straight", "hookL", "hookR", "upper", "over", "body"]
	var tally := {"up": 0, "down": 0, "side": 0}
	var hb := {"up": 0, "total": 0}   # hooks + body shots
	var upper_lift_p := -9.0
	var upper_lift_f := -9.0
	var slide_min := 9.0
	var slide_max := 0.0
	var settle_max := 0.0
	var clean := true
	for k in kinds:
		var per := {"up": 0, "down": 0, "side": 0}
		for i in KO_SAMPLES:
			var wr := RandomNumberGenerator.new()
			wr.seed = 77 + i
			var r := await scripted_ko(k, 1000 + i * 37 + kinds.find(k) * 7919, wr.randf_range(-0.5, 1.4))
			per[r["o"]] += 1
			tally[r["o"]] += 1
			if k in ["hookL", "hookR", "body"]:
				hb["total"] += 1
				if r["o"] == "up":
					hb["up"] += 1
			if k == "upper":
				upper_lift_p = maxf(upper_lift_p, r["lift_p"])
				upper_lift_f = maxf(upper_lift_f, r["lift_f"])
			slide_min = minf(slide_min, r["slide"])
			slide_max = maxf(slide_max, r["slide"])
			settle_max = maxf(settle_max, r["settle"])
			var st: Dictionary = r["stats"]
			clean = clean and not st["nan"] and st["ymin"] > -0.05 and st["maxdist"] < 3.0
		print("    %-8s face up %d / down %d / side %d" % [k, per["up"], per["down"], per["side"]])
	var total: int = tally["up"] + tally["down"] + tally["side"]
	var fu := float(tally["up"]) / total
	var fd := float(tally["down"]) / total
	print("    all: up %.0f %%  down %.0f %%  side %.0f %%  (%d KOs)" % [fu * 100.0, fd * 100.0, float(tally["side"]) / total * 100.0, total])
	check(fu <= 0.70, "face up in at most 70 %% of the KOs (%.0f %%)" % (fu * 100.0))
	check(fd >= 0.14 and fd <= 0.50, "face down in 14-50 %% of the KOs (%.0f %%)" % (fd * 100.0))
	check(tally["side"] > 0, "some KOs end on a side")
	check(float(hb["up"]) / hb["total"] <= 0.6, "hooks and body shots end face up in at most 60 %% of the KOs (%d / %d)" % [hb["up"], hb["total"]])
	check(upper_lift_p <= 0.15 and upper_lift_f <= 0.15, "uppercut KOs: pelvis / feet never rise more than 0.15 m (%.2f / %.2f m)" % [upper_lift_p, upper_lift_f])
	check(slide_min >= 0.1 and slide_max <= 0.7, "slide after the KO stays short (%.2f .. %.2f m)" % [slide_min, slide_max])
	check(settle_max <= 3.0 and settle_max > 0.0, "every body settles (calm after at most %.1f s)" % settle_max)
	check(clean, "no NaNs, nothing through the floor, no bone flying off in the batch")

	print("== C. knockdown: ragdoll -> count -> get-up blend -> IDLE, capsule under the body")
	var f := await make_match()
	var q1: Fighter = f[0]
	var p2: Fighter = f[1]
	q1.global_position = Vector3(-0.45, 0, 0)
	p2.global_position = Vector3(0.45, 0, 0)
	await steps(30)
	p2._do_knockdown("L")
	p2.getup_count = 4
	check(p2._ragdoll.active and p2.state == Fighter.State.FALL, "knockdown starts the ragdoll in FALL")
	var seen := {}
	var n := 0
	var getup_dist := 9.0
	var blend_seen := false
	var capsule_back := false
	var y_ok := true
	while n < 120 * 25 and not (n > 30 and p2.state == Fighter.State.IDLE):
		await steps(1)
		n += 1
		seen[p2.state_name] = true
		if p2.state == Fighter.State.GETUP and getup_dist > 8.0:
			var pel: Vector3 = p2._ragdoll.bone_origin("pelvis")
			getup_dist = Vector2(p2.global_position.x - pel.x, p2.global_position.z - pel.z).length()
		if p2.state == Fighter.State.GETUP and p2._ragdoll.blend.weight > 0.0:
			blend_seen = true
		if p2.state == Fighter.State.GETUP and not (p2.get_node("CollisionShape3D") as CollisionShape3D).disabled:
			capsule_back = true
		if not finite(p2.global_position) or p2.global_position.y < -0.05 or p2.global_position.y > 0.1:
			y_ok = false
	check(seen.has("fall") and seen.has("count") and seen.has("getup"), "fall -> count -> getup visited")
	check(p2.state == Fighter.State.IDLE and not p2._ragdoll.active, "back to IDLE with the simulation off (%.1f s)" % (n / 120.0))
	check(blend_seen, "get-up blended from the ragdoll pose")
	check(getup_dist < 0.2, "capsule moved under the body for the get-up (%.2f m from the pelvis)" % getup_dist)
	check(capsule_back, "capsule re-enabled for the get-up")
	check(y_ok, "capsule stays on the canvas through the whole sequence")
	var np := Vector2(p2.global_position.x, p2.global_position.z)
	check(np.length() < 3.2, "capsule inside the ring (%.2f, %.2f)" % [np.x, np.y])
	await steps(120)
	check(not p2.stats.rocked and not p2.hurt.active() and p2.stats.rock_grace > 0.0, "comes back clear-headed, with a short rock grace (no post get-up daze)")

	Engine.time_scale = 1.0
	print("PASS" if failures == 0 else "FAIL (%d)" % failures)
	quit(0 if failures == 0 else 1)
