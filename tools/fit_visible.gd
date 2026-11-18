extends "res://tools/measure_hits.gd"
## Fits the hit / hurt / guard volumes of every MESHY roster model to its visible skinned mesh, expressed in the frame of the VISIBLE
## (Meshy) skeleton bones, and writes scripts/fighter/hit_fit_vis.gd. This is the single source of truth for hit detection: the volumes
## ride the bones the player sees (scripts/fighter/meshy_skin.gd mounts them), not the hidden M3DMale gameplay skeleton.
##   <godot> --headless --fixed-fps 120 --path . --script res://tools/fit_visible.gd -- [models=meshy_viper,meshy_oak] [write=1]
## Same fitting maths as tools/measure_hits.gd (guard pose, baked vertices, percentile capsules / boxes / glove cap); only the bone frame
## differs. The local frames are orthonormal metres (the Meshy skeleton is in cm under a scaled armature).

const TORSO_ROUND := 0.5   ## corner radius of the chest / abdomen boxes as a share of the fitted maximum (see _fit_box_oriented)
var _xf_vis: Dictionary = {}   ## driver bone name -> world Transform3D (orthonormal) of the matching Meshy bone at the bake
var _vis_joint: Dictionary = {} ## driver bone name -> Meshy joint name


func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	var ids: Array = []
	for id in RosterScript.ORDER:
		if RosterScript.skin_path(id) != "":
			ids.append(id)
	if args.has("models"):
		ids = String(args["models"]).split(",")
	var fits := {}
	for id in ids:
		print("\n================ ", id)
		var f: Fighter = await _spawn(id, "guard")
		var groups := await _bake_vis(f)
		MeshBake.add_torso(groups, _xf)
		fits[id] = _fit_vis(groups, f)
		_report_vis(id, fits[id], groups)
		if args.get("rcscan", "0") == "1":
			for key in ["chest", "abdomen"]:
				var v0: Dictionary = fits[id][key]
				var dk0 := ""
				for k in _vis_joint:
					if _vis_joint[k] == v0["bone"]:
						dk0 = k
				var gk0: String = "t_chest" if key == "chest" else "t_abdomen"
				var pts0 := _local(groups[gk0], _xf_vis[dk0])
				var inv0 := Basis(v0["q"] as Quaternion).inverse()
				var rp0 := []
				for p in pts0:
					rp0.append(inv0 * (p as Vector3))
				for frac in [0.2, 0.35, 0.5, 0.65, 0.8, 1.0]:
					var vv := v0.duplicate()
					vv["rc"] = float(v0["rc"]) * frac
					var e := _eval(vv, rp0)
					print("   %s %s rc x%.2f (%.1f cm): surface-to-mesh mean %.1f p95 %.1f | mesh-to-volume mean %.1f | verts >1cm outside %.0f%%" % [id, key, frac, vv["rc"] * 100, e["mean"] * 100, e["p95"] * 100, e["vmean"] * 100, e["outside"] * 100])
		if args.get("poses", "0") == "1":   # the guard-pose fit judged in a slip (lean) and a duck: how far the skin leaves the rigid volumes
			for pose in ["slip", "duck"]:
				var f2: Fighter = await _spawn(id, pose)
				var g2 := await _bake_vis(f2)
				MeshBake.add_torso(g2, _xf)
				_report_pose(id, pose, fits[id], g2)
	if args.get("write", "0") == "1":
		_write_vis(fits)
	quit(0)


func _bake_vis(f: Fighter) -> Dictionary:
	_bake_pending = true
	var sk: Skeleton3D = f.rig.skeleton
	var cb := func():
		if _bake_pending:
			_bake_pending = false
			var r: Dictionary = MeshBake.bake(f)
			_bake = r["groups"]
			_xf = r["xf"]
			_xf_vis = {}
			var ms = f.meshy_skin
			for pair in ms.MAP:
				var i: int = ms.skeleton.find_bone(pair[0])
				var w: Transform3D = ms.skeleton.global_transform * ms.skeleton.get_bone_global_pose(i)
				_xf_vis[pair[1]] = Transform3D(w.basis.orthonormalized(), w.origin)
				_vis_joint[pair[1]] = pair[0]
	sk.skeleton_updated.connect(cb)
	for i in 4:
		await physics_frame
	sk.skeleton_updated.disconnect(cb)
	return _bake


## Rest-pose direction (in the Meshy bone's own orthonormal frame) from joint `a` to joint `b`.
func _vis_axis(f: Fighter, da: String, db: String) -> Vector3:
	var sk: Skeleton3D = f.meshy_skin.skeleton
	var ia := sk.find_bone(_vis_joint[da])
	var ib := sk.find_bone(_vis_joint[db])
	var ra := sk.get_bone_global_rest(ia)
	var rb := sk.get_bone_global_rest(ib)
	return (ra.basis.orthonormalized().inverse() * (rb.origin - ra.origin)).normalized()


func _fit_vis(groups: Dictionary, f: Fighter) -> Dictionary:
	var xf := _xf_vis
	var out := {}
	var hp := _local(groups["head"], xf["head"])
	var up_head: Vector3 = ((xf["head"] as Transform3D).basis.inverse() * Vector3.UP).normalized()   # the head stands upright in the guard pose
	out["head"] = _fit_capsule(hp, "head", PAD, 0.02, 0.98, up_head)
	if groups.has("neck"):
		var nl := _local(groups["neck"], xf["neckLower"])
		var naxis := _vis_axis(f, "neckLower", "head")
		out["neck"] = _fit_capsule(nl, "neckLower", PAD, 0.0, 1.0, naxis)
		out["neck"]["r"] = minf(float(out["neck"]["r"]), 0.075)
		out["neck"]["h"] = maxf(float(out["neck"]["h"]), float(out["neck"]["r"]) * 2.0 + 0.002)
	out["abdomen"] = _fit_box_oriented(_local(groups["t_abdomen"], xf["abdomenUpper"]), "abdomenUpper", (xf["abdomenUpper"] as Transform3D).basis.inverse() * f.global_basis.orthonormalized())
	out["chest"] = _fit_box_oriented(_local(groups["t_chest"], xf["chestUpper"]), "chestUpper", (xf["chestUpper"] as Transform3D).basis.inverse() * f.global_basis.orthonormalized())
	for side in ["l", "r"]:
		var hb := "%sHand" % side
		var hpts := _local(groups["hand_" + side], xf[hb])
		var cen := Vector3.ZERO
		for q in hpts:
			cen += q
		cen = (cen / maxf(hpts.size(), 1)).normalized()
		out[hb] = _fit_capsule(hpts, hb, 0.0, 0.02, 0.98, cen)
		var fist := _fit_glove(hpts, hb, 0.75, 0.85)
		fist["r"] = clampf(float(fist["r"]), 0.05, 0.07)
		out["%sFist" % side] = fist
		var fb := "%sForearmBend" % side
		var axis := _vis_axis(f, fb, hb)
		out[fb] = _fit_capsule(_local(groups["fore_" + side], xf[fb]), fb, 0.0, 0.03, 0.97, axis)
	for key in out:   # name the volumes after the Meshy joint they ride
		out[key]["bone"] = _vis_joint[out[key]["bone"]]
	return out


## Box fitted in the fighter's own axes (x left, y up, z forward), then expressed in the bone frame: `to_bone` maps fighter axes into the bone's frame.
func _fit_box_oriented(pts: Array, bone: String, to_bone: Basis) -> Dictionary:
	var inv := to_bone.inverse()
	var fp := []
	for p in pts:
		fp.append(inv * (p as Vector3))
	var v := _fit_box(fp, bone)
	v["rc"] = float(v["rc"]) * TORSO_ROUND   # a torso cross-section is rounder than a box but not a capsule: the full-radius corner left 35 % of the chest skin > 1 cm outside the hull
	v["off"] = to_bone * (v["off"] as Vector3)
	v["q"] = to_bone.get_rotation_quaternion()
	return v


func _report_vis(id: String, fit: Dictionary, groups: Dictionary) -> void:
	for key in fit:
		var v: Dictionary = fit[key]
		var gk: String = {"head": "head", "neck": "neck", "chest": "t_chest", "abdomen": "t_abdomen", "lHand": "hand_l", "rHand": "hand_r", "lFist": "hand_l", "rFist": "hand_r", "lForearmBend": "fore_l", "rForearmBend": "fore_r"}[key]
		var dk := ""
		for k in _vis_joint:
			if _vis_joint[k] == v["bone"]:
				dk = k
		var e := _eval(v, _local(groups[gk], _xf_vis[dk]))
		print("   %-13s on %-12s %-40s surface-to-mesh mean %.1f p95 %.1f cm | mesh-to-volume mean %.1f cm" % [key, v["bone"], _dims(v), e["mean"] * 100, e["p95"] * 100, e["vmean"] * 100])


func _report_pose(id: String, pose: String, fit: Dictionary, groups: Dictionary) -> void:
	var line := "   %s %-5s" % [id, pose]
	for key in ["head", "chest", "abdomen", "lHand", "lForearmBend"]:
		var v: Dictionary = fit[key]
		var gk: String = {"head": "head", "chest": "t_chest", "abdomen": "t_abdomen", "lHand": "hand_l", "lForearmBend": "fore_l"}[key]
		var dk := ""
		for k in _vis_joint:
			if _vis_joint[k] == v["bone"]:
				dk = k
		var xfp: Transform3D = _xf_vis[dk]
		var pts := _local(groups[gk], xfp)
		var vv := v.duplicate()
		var rot_pts := pts
		if v.has("q"):   # un-rotate the points into the box frame
			var inv := Basis(v["q"] as Quaternion).inverse()
			rot_pts = []
			for p in pts:
				rot_pts.append(inv * (p as Vector3))
		var e := _eval(vv, rot_pts)
		line += " | %s mesh-to-vol mean %.1f p90 %.1f, >1cm outside %.0f%%" % [key, e["vmean"] * 100, e["vp90"] * 100, e["outside"] * 100]
	print(line)


func _write_vis(fits: Dictionary) -> void:
	var s := "extends RefCounted\n## Per-model hit / hurt / guard volumes fitted to the visible Meshy skin by tools/fit_visible.gd (do not edit by hand; rerun the tool with write=1).\n"
	s += "## Volumes are in the local frame (orthonormal, metres) of the named MESHY joint: they ride the bones the player sees (meshy_skin.gd mounts).\n## kind: capsule (along `axis`) | box (rounded) | sphere.\n\nconst FIT := {\n"
	for id in fits:
		s += "\t\"%s\": {\n" % id
		for key in fits[id]:
			var v: Dictionary = fits[id][key]
			var line := "\t\t\"%s\": {\"bone\": \"%s\", \"kind\": \"%s\", \"off\": %s" % [key, v["bone"], v["kind"], _fmt_v(v["off"])]
			match v["kind"]:
				"capsule":
					line += ", \"axis\": %s, \"h\": %.4f, \"r\": %.4f" % [_fmt_v(v.get("axis", Vector3.UP)), v["h"], v["r"]]
				"box":
					var q: Quaternion = v.get("q", Quaternion.IDENTITY)
					line += ", \"half\": %s, \"rc\": %.4f, \"q\": Quaternion(%.5f, %.5f, %.5f, %.5f)" % [_fmt_v(v["half"]), v["rc"], q.x, q.y, q.z, q.w]
				"sphere":
					line += ", \"r\": %.4f" % v["r"]
			s += line + "},\n"
		s += "\t},\n"
	s += "}\n"
	var fa := FileAccess.open("res://scripts/fighter/hit_fit_vis.gd", FileAccess.WRITE)
	fa.store_string(s)
	fa.close()
	print("wrote scripts/fighter/hit_fit_vis.gd")
