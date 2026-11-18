extends SceneTree
## How far the gameplay fist sphere (and the head hull) sit from the VISIBLE glove cap / head while the pose changes: the root-cause number of the
## "the punch went through his head and it was a whiff" complaint.
##   <godot> --headless --fixed-fps 120 --path . --script res://tools/measure_sphere_offset.gd -- pair=meshy_viper:meshy_oak
## Visible glove cap = centroid of the 25 % of the glove skin samples farthest from the Meshy wrist joint (the same definition the fit used for the sphere).
## Reported per punch: max / mean distance between that point and the fist sphere centre (clamp_delta removed) over the strike, and for the foe the
## distance between the head hull centre and the visible head centroid while he leans (slip) and while he stands.

const SkinSampler := preload("res://tools/skin_sampler.gd")

var F: Array = []
var samplers: Array = []
var rows: Array = []   ## per frame: [glove dev, head dev]
var cap := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	var pr: Array = String(args.get("pair", "meshy_viper:meshy_oak")).split(":")
	for tag in ["LJab", "RJab", "LHook", "RHook", "LUppercut", "RUppercut"]:
		await _new(pr[0], pr[1])
		F[0].global_position = Vector3(-1.0, 0, 0)
		F[1].global_position = Vector3(1.0, 0, 0)
		await _steps(100)
		var inp := FighterInput.new()
		inp.strikes.append(tag)
		F[0].external_input = inp
		rows.clear()
		cap = true
		for k in 90:
			if k == 1:
				F[0].external_input = FighterInput.new()
			await physics_frame
			_sample(tag)
		cap = false
		var mx := 0.0
		var sm := 0.0
		for r in rows:
			mx = maxf(mx, r)
			sm += r
		print("   %-10s glove cap vs fist sphere: max %.1f cm, mean %.1f cm over %d frames" % [tag, mx * 100, sm / maxf(rows.size(), 1) * 100, rows.size()])
	for lean in [Vector2(0, 0), Vector2(1, 0), Vector2(0, -1), Vector2(-1, 0)]:
		await _new(pr[0], pr[1])
		await _steps(60)
		var d := FighterInput.new()
		d.lean = lean
		F[1].external_input = d
		var worst := 0.0
		for k in 90:
			await physics_frame
			if k > 30:
				var g: Dictionary = (samplers[1] as RefCounted).call("sample", ["head"])
				worst = maxf(worst, _head_hull_centre(F[1]).distance_to(SkinSampler.centroid(g["head"])))
		print("   foe lean %s: head hull centre vs visible head centroid, worst %.1f cm" % [str(lean), worst * 100])
	quit(0)


func _steps(n: int) -> void:
	for i in n:
		await physics_frame


var _m: Node


func _new(a: String, b: String) -> void:
	if _m != null and is_instance_valid(_m):
		_m.queue_free()
		await process_frame
	_m = load("res://scenes/match.tscn").instantiate()
	_m.setup({"intro_delay": 0.0, "mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy", "rounds": 1, "round_seconds": 900.0,
		"p1_model": a, "p2_model": b, "rules": "boxing"})
	get_root().add_child(_m)
	await process_frame
	F = _m.get_fighters()
	for f in F:
		f.external_input = FighterInput.new()
		f.stats.infinite_stamina = true
	samplers = [SkinSampler.make(F[0]), SkinSampler.make(F[1])]


func _head_hull_centre(f: Fighter) -> Vector3:
	for hu in f.rig.hurtboxes:
		if hu.zone == "head" and hu.limb == "head":
			return hu.shape_node.global_position
	return Vector3.INF


func _sample(_tag: String) -> void:
	var a: Fighter = F[0]
	if a.state != a.State.ATTACK:
		return
	var limb := String(a.atk["limb"])
	var side := "l" if limb.begins_with("l") else "r"
	var glove: PackedVector3Array = (samplers[0] as RefCounted).call("sample", ["hand_" + side])["hand_" + side]
	var wrist: Vector3 = a.meshy_skin.joint_world("LeftHand" if side == "l" else "RightHand")
	var ds := []
	for p in glove:
		ds.append(p.distance_to(wrist))
	ds.sort()
	var cut: float = ds[int(ds.size() * 0.75)]
	var c := Vector3.ZERO
	var n := 0
	for p in glove:
		if p.distance_to(wrist) >= cut:
			c += p
			n += 1
	c /= maxf(n, 1)
	var hb: HitAreas.Hitbox = a.rig.hitbox_for(limb)[0]
	var cd = hb.get("clamp_delta")   # (absent before the impact layer existed)
	var s: Vector3 = (hb.shapes[0]["node"] as CollisionShape3D).global_position - (cd if cd != null else Vector3.ZERO)
	rows.append(c.distance_to(s))
