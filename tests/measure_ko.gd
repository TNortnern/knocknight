extends SceneTree
# Batch of scripted KOs: orientation / slide / lift / settle per sample.
# godot --headless --fixed-fps 120 --path . --script res://tests/measure_ko.gd -- kinds=hookL,upper n=6
var m: Match
var TRACE := false
var FIXED_WALK := -99.0

func _initialize() -> void:
	_run.call_deferred()

func steps(n: int) -> void:
	for i in n:
		await physics_frame

var SHOTS := ""
var main_node: Node

func make_match() -> Array:
	if SHOTS != "":
		if main_node != null:
			main_node.queue_free()
			await process_frame
		main_node = load("res://scenes/main.tscn").instantiate()
		get_root().add_child(main_node)
		await process_frame
		main_node.start_match({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy", "p1_model": "viper", "p2_model": "anvil", "rules": "boxing", "rounds": 3, "round_seconds": 180.0, "cpu_difficulty": "normal", "arena": "ring", "intro_delay": 0.0})
		await steps(60)
		var ff: Array = main_node.current_match.get_fighters()
		ff[0].external_input = FighterInput.new()
		ff[1].external_input = FighterInput.new()
		await steps(10)
		return ff
	if m != null:
		get_root().remove_child(m)
		m.queue_free()
		await process_frame
	m = load("res://scenes/match.tscn").instantiate()
	m.setup({"intro_delay": 0.0, "mode": "exhibition", "rounds": 1, "round_seconds": 600.0, "p1_controller": "dummy", "p2_controller": "dummy",
		"p1_model": "viper", "p2_model": "anvil", "rules": "boxing"})
	get_root().add_child(m)
	await process_frame
	var f: Array = m.get_fighters()
	f[0].external_input = FighterInput.new()
	f[1].external_input = FighterInput.new()
	await steps(70)
	return f

func classify(rd) -> String:
	var c: float = (rd.bones["chest"] as PhysicalBone3D).global_basis.z.y
	var p: float = (rd.bones["pelvis"] as PhysicalBone3D).global_basis.z.y
	var s := 0.7 * c + 0.3 * p
	if s > 0.3: return "up"
	if s < -0.3: return "down"
	return "side"

func one(kind: String, seed_: int, walk: float) -> Dictionary:
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
		"jab": limb = "L"
		"straight": pass
		"hookL": prefix = "L"; d = (away * 0.55 - lat * 0.85).normalized(); limb = "L"
		"hookR": prefix = "R"; d = (away * 0.55 + lat * 0.85).normalized()
		"upper": prefix = "U"; d = (away * 0.5 + Vector3.UP * 0.9).normalized()
		"over": prefix = "O"; d = (away * 0.6 + Vector3.DOWN * 0.8).normalized()
		"body": zone = "body"; d = (away + Vector3.DOWN * 0.2).normalized()
	var hp: Vector3 = rd.head_position() if zone == "head" else rd.pelvis_position()
	p2._last_hit = {"t": p2._time, "ev": {"position": hp, "speed": 4.5, "velocity": d * 4.5}, "strike": {"limb": limb}}
	for id in rd.bones:
		rd._lin_vel[id] = -away * walk
	var start := p2.global_position
	p2._do_ko("tko", prefix, zone)
	await steps(1)
	var pel0: float = rd.pelvis_position().y
	var feet0: float = maxf(rd.bone_origin("lFoot").y, rd.bone_origin("rFoot").y)
	var lift_p := -9.0
	var lift_f := -9.0
	var settle := -1.0
	var n := 0
	var vmax_late := 0.0
	while n < 120 * 6:
		await steps(1)
		n += 1
		lift_p = maxf(lift_p, rd.pelvis_position().y - pel0)
		for id in ["lFoot", "rFoot"]:
			lift_f = maxf(lift_f, (rd.bones[id] as PhysicalBone3D).global_position.y - feet0)
		if SHOTS != "" and n % 12 == 0 and n <= 12 * 40:
			get_root().get_viewport().get_texture().get_image().save_png("res://_build/shots/%s_%02d.png" % [SHOTS, n / 12])
		if TRACE and n % 12 == 0 and n >= 36 and n <= 360:
			var pb: PhysicalBone3D = rd.bones["pelvis"]
			var cb: PhysicalBone3D = rd.bones["chest"]
			var rel: Vector3 = cb.global_position - pb.global_position
			print("     t %.2f pel y %.2f x %.2f | chest rel fwd(+x) %.2f up %.2f | chest face.y %.2f pelvis face.y %.2f | head y %.2f | knee %.0f %.0f" % [n / 120.0, pb.global_position.y, pb.global_position.x - 0.4, rel.x, rel.y, cb.global_basis.z.y, pb.global_basis.z.y, rd.head_position().y, rd.knee_flex("l"), rd.knee_flex("r")])
		if settle < 0.0 and rd.calm():
			settle = n / 120.0
	var pel: Vector3 = rd.pelvis_position()
	var slide := Vector2(pel.x - start.x, pel.z - start.z).length()
	var ymin := 9.0
	for id in rd.bones:
		ymin = minf(ymin, (rd.bones[id] as PhysicalBone3D).global_position.y)
	return {"cz": (rd.bones["chest"] as PhysicalBone3D).global_basis.z.y, "pz": (rd.bones["pelvis"] as PhysicalBone3D).global_basis.z.y, "pitch": rd._pitch, "roll": rd._roll, "o": classify(rd), "slide": slide, "lift_p": lift_p, "lift_f": lift_f, "settle": settle, "ymin": ymin}

func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		if kv.size() == 2: args[kv[0]] = kv[1]
	var kinds: PackedStringArray = String(args.get("kinds", "jab,straight,hookL,hookR,upper,over,body")).split(",")
	var n := int(args.get("n", "6"))
	TRACE = args.get("trace", "0") == "1"
	SHOTS = args.get("shots", "")
	if args.has("walk"):
		FIXED_WALK = float(args["walk"])
	var tot := {"up": 0, "down": 0, "side": 0}
	for k in kinds:
		var cnt := {"up": 0, "down": 0, "side": 0}
		var smin := 9.0
		var smax := 0.0
		var lp := -9.0
		var lf := -9.0
		var stl := 0.0
		var ymn := 9.0
		for i in range(int(args.get("from", "0")), int(args.get("from", "0")) + n):
			var wr := RandomNumberGenerator.new()
			wr.seed = 77 + i
			var walk := wr.randf_range(-0.5, 1.4)
			if FIXED_WALK > -90.0:
				walk = FIXED_WALK
			var r := await one(k, 1000 + i * 37 + ["jab", "straight", "hookL", "hookR", "upper", "over", "body"].find(k) * 7919, walk)
			cnt[r["o"]] += 1
			tot[r["o"]] += 1
			smin = minf(smin, r["slide"]); smax = maxf(smax, r["slide"])
			lp = maxf(lp, r["lift_p"]); lf = maxf(lf, r["lift_f"]); stl = maxf(stl, r["settle"]); ymn = minf(ymn, r["ymin"])
			print("   %s #%d walk %.2f pitch %.2f roll %.2f -> %s slide %.2f lift p %.2f f %.2f settle %.2f chest %.2f pelvis %.2f" % [k, i, walk, r["pitch"], r["roll"], r["o"], r["slide"], r["lift_p"], r["lift_f"], r["settle"], r["cz"], r["pz"]])
		print("KIND %s up %d down %d side %d | slide %.2f..%.2f lift pelvis %.2f feet %.2f settle max %.2f ymin %.3f" % [k, cnt["up"], cnt["down"], cnt["side"], smin, smax, lp, lf, stl, ymn])
	print("TOTAL ", tot)
	quit(0)
