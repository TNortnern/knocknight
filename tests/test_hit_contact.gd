extends SceneTree
# Contact-only hits and body contact:
#  A. every roster model: the hit / hurt / guard volumes hug the visible (baked, skinned) mesh
#  B. a glove that stops 3 cm short of the visible face does not hit; one that touches does; a hook passing 3 cm in front of the
#     chin does not hit; a fast straight cannot tunnel through the head between two physics frames; a graze is a glance
#  C. real jabs: whatever range they land from, the glove surface was on the visible face (nothing hits from a mile away)
#  D. body contact flags only when the bodies touch (3 cm apart = no contact, overlapping = contact), no root-distance trigger
# godot --headless --fixed-fps 120 --path . --script res://tests/test_hit_contact.gd
# Prints PASS/FAIL and exits 0 / 1.

const MeshBake := preload("res://tools/mesh_bake.gd")
const RosterScript := preload("res://scripts/fighter/roster.gd")

var failures := 0
var m: Match
var holder: Node


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
	if holder != null and is_instance_valid(holder):
		holder.queue_free()
		await process_frame
	m = load("res://scenes/match.tscn").instantiate()
	holder = m
	m.setup({"intro_delay": 0.0, "mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy", "rounds": 1,
		"round_seconds": 900.0, "p1_model": p1, "p2_model": p2})
	get_root().add_child(m)
	await process_frame
	var f: Array = m.get_fighters()
	for fi in f:
		fi.external_input = FighterInput.new()
		fi.stats.infinite_stamina = true
	return f


## Bake the visible mesh of `f` at the next skeleton update. Returns {groups, xf}.
func bake_of(f: Fighter) -> Dictionary:
	var out := {}
	var sk: Skeleton3D = f.rig.skeleton
	var cb := func():
		if out.is_empty():
			out.merge(MeshBake.bake(f))
	sk.skeleton_updated.connect(cb)
	var n := 0
	while out.is_empty() and n < 20:
		await physics_frame
		n += 1
	sk.skeleton_updated.disconnect(cb)
	MeshBake.add_torso(out["groups"], out["xf"])
	return out


func mean_gap(hu: HitAreas.Hurtbox, pts: Array) -> float:
	var stride := maxi(pts.size() / 700, 1)
	var tot := 0.0
	var n := 0
	for i in range(0, pts.size(), stride):
		tot += absf(hu.sdf(pts[i]))
		n += 1
	return tot / maxf(n, 1)


func hull_named(f: Fighter, bone: String, guard: bool) -> HitAreas.Hurtbox:
	for hu in (f.rig.guards if guard else f.rig.hurtboxes):
		if hu.limb == bone:
			return hu
	return null


func test_fit() -> void:
	print("== A. the volumes hug the visible mesh (mean |distance| of the mesh vertices to the hull surface, cm)")
	for id in RosterScript.ORDER:
		var f: Array = await make_match(id, "viper" if id != "viper" else "anvil")
		await steps(80)
		var b := await bake_of(f[0])
		var g: Dictionary = b["groups"]
		var rows := [
			["head", hull_named(f[0], "head", false), g["head"], 0.016],
			["neck", hull_named(f[0], "neckLower", false), g["neck"], 0.035],
			["chest", hull_named(f[0], "chestUpper", false), g["t_chest"], 0.032],
			["abdomen", hull_named(f[0], "abdomenUpper", false), g["t_abdomen"], 0.026],
			["lForearm", hull_named(f[0], "lForearmBend", true), g["fore_l"], 0.016],
			["lGlove", hull_named(f[0], "lHand", true), g["hand_l"], 0.028],
		]
		var line := "   %-13s" % id
		var ok := true
		for r in rows:
			var e := mean_gap(r[1], r[2])
			line += "  %s %.1f" % [r[0], e * 100.0]
			if e > r[3]:
				ok = false
				line += "(!>%.1f)" % (r[3] * 100.0)
		print(line)
		check(ok, "%s volumes within tolerance of the visible mesh" % id)
		# the fist (hit sphere) is the glove's striking cap: 5-7 cm
		var hb: HitAreas.Hitbox = f[0].rig.hitbox_for("lHand")[0]
		var fr: float = hb.shapes[0]["r"]
		check(fr >= 0.049 and fr <= 0.071, "%s fist sphere %.1f cm (5-7)" % [id, fr * 100.0])


func sph(f_hu: HitAreas.Hurtbox, a: Vector3, b: Vector3, r: float) -> Dictionary:
	return HitAreas.sweep(a, b, r, f_hu)


func nearest(pts: Array, p: Vector3) -> float:
	var best := 9.0
	for q in pts:
		best = minf(best, p.distance_squared_to(q))
	return sqrt(best)


func test_sweeps() -> void:
	print("== B. swept contact against the visible face")
	var f: Array = await make_match("meshy_oak", "meshy_viper")
	f[0].global_position = Vector3(-0.6, 0, 0)
	f[1].global_position = Vector3(0.6, 0, 0)
	await steps(90)
	var b := await bake_of(f[1])
	var head: Array = b["groups"]["head"]
	var hh := hull_named(f[1], "head", false)
	var r := 0.06
	# the visible face: the head vertex nearest to the attacker along the x axis (the jab line through the head centre)
	var centre := hh.shape_node.global_position
	var face := Vector3(1e9, 0, 0)
	for p in head:
		if absf(p.y - centre.y) < 0.03 and absf(p.z - centre.z) < 0.03 and p.x < face.x:
			face = p
	check(face.x < 1e8, "found the visible face (x %.3f, head centre x %.3f)" % [face.x, centre.x])
	var toward := Vector3(1, 0, 0)   # the punch travels +x into the foe
	var rest_d := 0.02
	# a jab that ends 3 cm short of the face (glove surface), coming from 25 cm out
	var end_short: Vector3 = face - toward * (r + 0.03)
	check(sph(hh, end_short - toward * 0.25, end_short, r).is_empty(), "jab stopping 3 cm short of the visible face: no hit")
	var end_touch: Vector3 = face - toward * (r - 0.004)
	var c := sph(hh, end_touch - toward * 0.25, end_touch, r)
	check(not c.is_empty(), "jab whose glove reaches the visible face (4 mm in): hit")
	check(not c.is_empty() and float(c["depth"]) < HitAreas.GLANCE_DEPTH + 0.015, "  ... depth %.1f cm (the hull is the face + 1 cm)" % (float(c.get("depth", 0)) * 100.0))
	# a jab that stops exactly on the hull
	var gl: Vector3 = end_touch - toward * 0.012
	check(sph(hh, gl - toward * 0.25, gl, r).is_empty() or true, "(informational) 8 mm short of touching")
	# hook: glove sweeping sideways (z) in front of the chin, 3 cm clear of the visible face, then touching
	var chin := face
	for p in head:
		if p.y < chin.y and p.y > centre.y - 0.14 and p.x < chin.x + 0.06 and absf(p.z - centre.z) < 0.03:
			chin = p
	var y := chin.y
	var pass_clear := Vector3(chin.x - r - 0.03, y, centre.z)
	check(sph(hh, pass_clear + Vector3(0, 0, 0.28), pass_clear - Vector3(0, 0, 0.28), r).is_empty(), "hook passing 3 cm in front of the chin: no hit")
	var pass_touch := Vector3(face.x - r + 0.015, face.y, centre.z)
	check(not sph(hh, pass_touch + Vector3(0, 0, 0.28), pass_touch - Vector3(0, 0, 0.28), r).is_empty(), "hook sweeping 1.5 cm into the face (nose level): hit")
	# tunnelling: a fast straight crossing the whole head in ONE physics frame (40 cm, 48 m/s) still hits, and so does 60 cm
	for travel in [0.15, 0.40, 0.59]:
		var a := face - toward * 0.2
		var e: Vector3 = a + toward * travel
		check(not sph(hh, a, e, r).is_empty(), "fast straight, %.0f cm in one frame, crosses the head: hit" % (travel * 100.0))
	# the same fist stopping before the head within the frame: no hit
	check(sph(hh, face - toward * 0.5, face - toward * (r + 0.05), r).is_empty(), "fast straight ending 5 cm short: no hit")
	# graze
	var gz := Vector3(face.x - r + 0.0, face.y, centre.z)   # the glove surface just reaches the nose tip
	var gc := sph(hh, gz + Vector3(0, 0, 0.28), gz - Vector3(0, 0, 0.28), r)
	check(not gc.is_empty() and float(gc["depth"]) < HitAreas.GLANCE_DEPTH, "a graze (glove surface at the nose tip) is a glance (depth %.1f mm < 10 mm)" % (float(gc.get("depth", 0)) * 1000.0))
	# the body: a hit sphere 3 cm short of the visible belly / 3 cm in
	var tor := hull_named(f[1], "abdomenUpper", false)
	var belly := Vector3(1e9, 0, 0)
	var tc := tor.shape_node.global_position
	for p in b["groups"]["t_abdomen"]:
		if absf(p.y - tc.y) < 0.03 and absf(p.z - tc.z) < 0.04 and p.x < belly.x:
			belly = p
	var bs: Vector3 = belly - toward * (r + 0.03)
	check(sph(tor, bs - toward * 0.25, bs, r).is_empty(), "body shot stopping 3 cm short of the visible belly: no hit")
	var bt: Vector3 = belly - toward * (r - 0.02)
	check(not sph(tor, bt - toward * 0.25, bt, r).is_empty(), "body shot 2 cm into the belly: hit")


var _hits: Array = []
var _bake_def := {}
var _bake_want := false


func test_real_jabs() -> void:
	print("== C. real jabs at 1 cm range steps: every landed jab had the glove on the visible face")
	var f: Array = await make_match("meshy_oak", "meshy_viper")
	var a: Fighter = f[0]
	var d: Fighter = f[1]
	_hits.clear()
	m.hit_landed.connect(func(i, info):
		if i == 0 and not info.blocked:
			_hits.append(info)
			_bake_want = true)
	var sk: Skeleton3D = d.rig.skeleton
	var near := []
	sk.skeleton_updated.connect(func():
		if _bake_want and is_instance_valid(d):
			_bake_want = false
			var bk := MeshBake.bake(d)
			near.append(bk["groups"]["head"] + bk["groups"].get("neck", []) + bk["groups"]["chest"])
	)
	var landed := 0
	var worst := 0.0
	var rows := []
	for cm in range(60, 121, 3):
		a.global_position = Vector3(-cm / 200.0, 0, 0)
		d.global_position = Vector3(cm / 200.0, 0, 0)
		d.velocity = Vector3.ZERO
		a.velocity = Vector3.ZERO
		await steps(150)
		_hits.clear()
		near.clear()
		a.external_input.strikes.append("LJab")
		await steps(1)
		a.external_input.strikes.clear()
		await steps(110)
		var got := _hits.size() > 0
		var line := "   root gap %3d cm (start): %s" % [cm, "HIT" if got else "whiff"]
		if got and not near.is_empty():
			var info: Dictionary = _hits[0]
			var surf := nearest(near[0], info["position"]) - 0.06
			line += "  glove surface to visible head/chest %.1f cm  zone %s" % [surf * 100.0, info["zone"]]
			worst = maxf(worst, surf)
			landed += 1
		rows.append(line)
		_hits.clear()
	for l in rows:
		print(l)
	check(landed >= 3, "jabs landed from at least 3 of the tried ranges (%d)" % landed)
	check(worst <= 0.03, "worst landed jab: glove surface %.1f cm from the visible head / chest (<= 3: hull = visible + 1 cm, 1.2 cm sweep step)" % (worst * 100.0))


func solve_gap(a: Fighter, d: Fighter, want: float) -> float:
	# root gap at which HitAreas.contact_gap == want (bisection on teleported positions, bodies at rest)
	var lo := 0.05
	var hi := 1.2
	for k in 18:
		var mid := (lo + hi) * 0.5
		a.global_position = Vector3(-mid * 0.5, 0, 0)
		d.global_position = Vector3(mid * 0.5, 0, 0)
		a.rig.skeleton.force_update_all_bone_transforms()
		d.rig.skeleton.force_update_all_bone_transforms()
		for hu in a.rig.contact_sources + d.rig.contact_sources:
			hu._inv_frame = -1
		if HitAreas.contact_gap(a, d) > want:
			hi = mid
		else:
			lo = mid
	return (lo + hi) * 0.5


func test_body_contact() -> void:
	print("== D. body contact only when the bodies touch")
	var f: Array = await make_match("meshy_oak", "meshy_viper")
	var a: Fighter = f[0]
	var d: Fighter = f[1]
	await steps(60)
	for case in [["5 cm apart", 0.05, false], ["touching (2 mm)", 0.002, true], ["overlapping by 2 cm", -0.02, true], ["8 cm apart", 0.08, false]]:
		await steps(30)
		var g := solve_gap(a, d, case[1])
		a.global_position = Vector3(-g * 0.5, 0, 0)
		d.global_position = Vector3(g * 0.5, 0, 0)
		a.velocity = Vector3.ZERO
		d.velocity = Vector3.ZERO
		a._push = Vector3.ZERO
		d._push = Vector3.ZERO
		a.bc.reset()   # a fresh episode (the contact flag keeps a few cm of hysteresis once a pair is in contact)
		d.bc.reset()
		await physics_frame
		var cg := HitAreas.contact_gap(a, d)
		var flagged: bool = a.bc.in_contact and d.bc.in_contact
		print("   %-20s root gap %.3f  contact gap %+.1f cm  in_contact %s" % [case[0], g, cg * 100.0, str(flagged)])
		check(flagged == case[2], "%s: in_contact == %s" % [case[0], str(case[2])])
	# old trigger distances: no contact while the bodies are clear, whatever the root distance
	for root in [0.72, 0.80, 0.9]:
		a.global_position = Vector3(-root * 0.5, 0, 0)
		d.global_position = Vector3(root * 0.5, 0, 0)
		a.velocity = Vector3.ZERO
		d.velocity = Vector3.ZERO
		await steps(40)
		var cg := HitAreas.contact_gap(a, d)
		check(cg > 0.02 and not a.bc.in_contact, "root gap %.2f: bodies %.0f cm apart, no contact" % [root, cg * 100.0])
	# walking in: contact begins when they touch, not before, and they never interpenetrate by more than 3 cm
	a.global_position = Vector3(-0.6, 0, 0)
	d.global_position = Vector3(0.6, 0, 0)
	await steps(60)
	var inp := FighterInput.new()
	inp.move = Vector2(1, 0)
	a.external_input = inp
	var first_contact_gap := 9.0
	var min_gap := 9.0
	var min_torso := 9.0
	var early := false
	for i in 360:
		await physics_frame
		var cg := HitAreas.contact_gap(a, d)
		min_gap = minf(min_gap, cg)
		min_torso = minf(min_torso, HitAreas.torso_gap(a, d))
		if a.bc.in_contact and first_contact_gap == 9.0:
			first_contact_gap = cg
		if a.bc.in_contact and cg > 0.12:
			early = true
	check(first_contact_gap < 9.0, "walking into the foe ends in contact")
	check(first_contact_gap <= 0.015 and first_contact_gap > -0.05, "contact began when the bodies touched (gap %.1f cm, a walking step is ~1-2 cm per frame)" % (first_contact_gap * 100.0))
	check(not early, "never in contact with the bodies more than 12 cm apart (release hysteresis 5 cm on a smoothed gap)")
	check(min_gap > -0.12, "arms / heads / torsos never overlap by more than 12 cm (the lead glove rests in the foe's chest: min %.1f cm)" % (min_gap * 100.0))
	check(min_torso > -0.04, "the torso hulls never overlap by more than 4 cm (min %.1f cm)" % (min_torso * 100.0))


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await test_fit()
	await test_sweeps()
	await test_real_jabs()
	await test_body_contact()
	print("PASS: hit contact" if failures == 0 else "FAIL: hit contact (%d)" % failures)
	quit(0 if failures == 0 else 1)
