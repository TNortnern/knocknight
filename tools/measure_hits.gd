extends SceneTree
## Measures the VISIBLE skinned body (M3DMale or Meshy skin, baked vertex by vertex) in guard / slip / duck poses and fits the
## hit / hurt / guard volumes to it, per roster model. Prints how far the OLD volumes stick out past the mesh and the NEW fit.
##   <godot> --headless --fixed-fps 120 --path . --script res://tools/measure_hits.gd -- [models=viper,meshy_oak] [write=1]
## write=1 regenerates scripts/fighter/hit_fit.gd (the per-model volume table FighterRig builds from).
## Volumes are expressed in the frame of a gameplay-skeleton (M3DMale) bone, which is where FighterRig attaches them.

const RosterScript := preload("res://scripts/fighter/roster.gd")

const POSES := ["guard", "slip", "duck"]
const PAD := 0.01   ## the head volume is the visible head + this

var _bake_pending := false
var _bake: Dictionary = {}   ## group -> PackedVector3Array (world)
var _xf: Dictionary = {}     ## driver bone -> world Transform3D at the bake


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	var ids: Array = String(args.get("models", ",".join(RosterScript.ORDER))).split(",")
	var fits := {}
	var report := {}
	for id in ids:
		print("\n================ ", id)
		var per_pose := {}
		var fighter_fit := {}
		for pose in POSES:
			var f: Fighter = await _spawn(id, pose)
			var groups := await _bake_now(f)
			MeshBake.add_torso(groups, _xf)
			per_pose[pose] = {"groups": groups, "xf": _xf.duplicate()}
			if pose == "guard":
				fighter_fit = _fit(groups, _xf, f)
		fits[id] = fighter_fit
		report[id] = await _report(id, fighter_fit, per_pose)
	if args.get("write", "0") == "1":
		_write_table(fits)
	quit(0)


var _holder: Node
func _spawn(id: String, pose: String) -> Fighter:
	if _holder != null and is_instance_valid(_holder):
		_holder.queue_free()
		await process_frame
	var m: Node = load("res://scenes/match.tscn").instantiate()
	_holder = m
	m.setup({"intro_delay": 0.0, "mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy", "rounds": 1,
		"round_seconds": 600.0, "p1_model": id, "p2_model": id})
	get_root().add_child(m)
	await process_frame
	var f: Array = m.get_fighters()
	var a: Fighter = f[0]
	a.global_position = Vector3(-2.0, 0, 0)
	f[1].global_position = Vector3(2.0, 0, 0)
	a.external_input = FighterInput.new()
	f[1].external_input = FighterInput.new()
	f[1].stats.infinite_stamina = true
	for i in 90:
		await physics_frame
	match pose:
		"slip":
			a.external_input.lean = Vector2(1.0, 0.0)
		"duck":
			a.external_input.duck = true
	if pose != "guard":
		for i in 50:
			await physics_frame
	return a


const MeshBake := preload("res://tools/mesh_bake.gd")


func _bake_now(f: Fighter) -> Dictionary:
	_bake_pending = true
	var sk: Skeleton3D = f.rig.skeleton
	var cb := func():
		if _bake_pending:
			_bake_pending = false
			var r: Dictionary = MeshBake.bake(f)
			_bake = r["groups"]
			_xf = r["xf"]
	sk.skeleton_updated.connect(cb)
	for i in 4:
		await physics_frame
	sk.skeleton_updated.disconnect(cb)
	return _bake


# ------------------------------------------------------------------ fitting (in the frame of the driver bone)
static func _local(world: Array, xf: Transform3D) -> Array:
	var inv := xf.affine_inverse()
	var out := []
	out.resize(world.size())
	for i in world.size():
		out[i] = inv * world[i]
	return out


static func _pct(vals: Array, q: float) -> float:
	if vals.is_empty():
		return 0.0
	var s := vals.duplicate()
	s.sort()
	return float(s[clampi(int(round(q * (s.size() - 1))), 0, s.size() - 1)])


static func _axis_vals(pts: Array, ax: int) -> Array:
	var v := []
	for p in pts:
		v.append(p[ax])
	return v


## Fit for one pose's baked groups. Returns {volume name: {...}} (see hit_fit.gd). `rig` gives the rest offsets (limb axes).
func _fit(groups: Dictionary, xf: Dictionary, f: Fighter) -> Dictionary:
	var out := {}
	var hp := _local(groups["head"], xf["head"])
	var np := _local(groups.get("neck", []), xf["head"])
	# head + neck: a straight that lands on the jaw / throat is a head shot (the jab clips end at chin level); the radius is the head's
	out["head"] = _fit_capsule(hp, "head", PAD, 0.02, 0.98, Vector3.UP)
	# the neck: its own capsule (zone head: the jab clips end at chin / throat height, a glove on the throat is a head shot)
	if not np.is_empty() and groups.has("neck"):
		var nl := _local(groups["neck"], xf["neckLower"])
		var naxis: Vector3 = f.rig._rest_offset("neckLower", "head").normalized()
		out["neck"] = _fit_capsule(nl, "neckLower", PAD, 0.0, 1.0, naxis)
		out["neck"]["r"] = minf(float(out["neck"]["r"]), 0.075)   # the Meshy neck group includes the trapezius: a real neck is ~15 cm across
		out["neck"]["h"] = maxf(float(out["neck"]["h"]), float(out["neck"]["r"]) * 2.0 + 0.002)
	out["abdomen"] = _fit_box(_local(groups["t_abdomen"], xf["abdomenUpper"]), "abdomenUpper")
	out["chest"] = _fit_box(_local(groups["t_chest"], xf["chestUpper"]), "chestUpper")
	for side in ["l", "r"]:
		var hb := "%sHand" % side
		var hpts := _local(groups["hand_" + side], xf[hb])
		var cen := Vector3.ZERO
		for q in hpts:
			cen += q
		cen = (cen / maxf(hpts.size(), 1)).normalized()
		out[hb] = _fit_capsule(hpts, hb, 0.0, 0.02, 0.98, cen)   # the whole glove (guard volume): a capsule along the hand
		var fist := _fit_glove(hpts, hb, 0.75, 0.85)
		fist["r"] = clampf(float(fist["r"]), 0.05, 0.07)   # the striking cap of the glove (knuckles), not the whole mitt
		out["%sFist" % side] = fist
		var fb := "%sForearmBend" % side
		var axis: Vector3 = f.rig._rest_offset(fb, hb).normalized()
		out[fb] = _fit_capsule(_local(groups["fore_" + side], xf[fb]), fb, 0.0, 0.03, 0.97, axis)
	return out


func _fit_capsule(pts: Array, bone: String, pad: float, ql: float, qh: float, axis: Vector3, rpts := []) -> Dictionary:
	var ts := []
	for p in pts:
		ts.append((p as Vector3).dot(axis))
	var t0 := _pct(ts, ql)
	var t1 := _pct(ts, qh)
	var inband := []
	for p in (rpts if not rpts.is_empty() else pts):
		var t: float = (p as Vector3).dot(axis)
		if rpts.is_empty() and (t < t0 or t > t1):
			continue
		inband.append((p as Vector3) - axis * t)
	# centre line: middle of the cross-section extent in the plane perpendicular to the axis
	var u := axis.cross(Vector3.FORWARD if absf(axis.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
	var w := axis.cross(u)
	var us := []
	var ws := []
	for q in inband:
		us.append((q as Vector3).dot(u))
		ws.append((q as Vector3).dot(w))
	var cu := (_pct(us, 0.03) + _pct(us, 0.97)) * 0.5
	var cw := (_pct(ws, 0.03) + _pct(ws, 0.97)) * 0.5
	var r := (((_pct(us, 0.97) - _pct(us, 0.03)) + (_pct(ws, 0.97) - _pct(ws, 0.03))) * 0.25)
	if bone != "head":
		var rs := []
		for q in inband:
			rs.append(Vector2((q as Vector3).dot(u) - cu, (q as Vector3).dot(w) - cw).length())
		r = _pct(rs, 0.9 if bone != "lHand" and bone != "rHand" else 0.85)
	r += pad
	var h := (t1 - t0) + 2.0 * pad
	var off := axis * ((t0 + t1) * 0.5) + u * cu + w * cw
	return {"bone": bone, "kind": "capsule", "axis": axis, "off": off, "h": maxf(h, r * 2.0 + 0.002), "r": r}


func _fit_box(pts: Array, bone: String) -> Dictionary:
	var xs := _axis_vals(pts, 0)
	var ys := _axis_vals(pts, 1)
	var zs := _axis_vals(pts, 2)
	var x0 := _pct(xs, 0.03)
	var x1 := _pct(xs, 0.97)
	var y0 := _pct(ys, 0.02)
	var y1 := _pct(ys, 0.98)
	var z0 := _pct(zs, 0.03)
	var z1 := _pct(zs, 0.97)
	var half := Vector3((x1 - x0) * 0.5, (y1 - y0) * 0.5, (z1 - z0) * 0.5)
	return {"bone": bone, "kind": "box", "off": Vector3((x0 + x1) * 0.5, (y0 + y1) * 0.5, (z0 + z1) * 0.5), "half": half, "rc": minf(minf(half.x, half.z) * 0.97, half.y * 0.97)}


func _fit_glove(pts: Array, bone: String, cut_q: float, r_q: float) -> Dictionary:
	# the glove is the fist ball: centroid of the vertices farthest from the wrist, radius = their spread
	var far := []
	var hx := _axis_vals(pts, 0)
	var hy := _axis_vals(pts, 1)
	var hz := _axis_vals(pts, 2)
	print("      %s hand verts %d extents x %.1f..%.1f y %.1f..%.1f z %.1f..%.1f cm" % [bone, pts.size(), _pct(hx, 0.02) * 100, _pct(hx, 0.98) * 100, _pct(hy, 0.02) * 100, _pct(hy, 0.98) * 100, _pct(hz, 0.02) * 100, _pct(hz, 0.98) * 100])
	for p in pts:
		far.append(p.length())
	var cut := _pct(far, cut_q)
	var c := Vector3.ZERO
	var n := 0
	for p in pts:
		if p.length() >= cut:
			c += p
			n += 1
	c /= maxf(n, 1)
	var ds := []
	for p in pts:
		if p.length() >= cut:
			ds.append(p.distance_to(c))
	return {"bone": bone, "kind": "sphere", "off": c, "r": _pct(ds, r_q)}


# ------------------------------------------------------------------ evaluation of old / new volumes
## Signed distance of p (bone-local) to a volume dictionary (negative inside).
static func sdf(v: Dictionary, p: Vector3) -> float:
	var q: Vector3 = p - (v["off"] as Vector3)
	match v["kind"]:
		"sphere":
			return q.length() - float(v["r"])
		"capsule":
			var ax: Vector3 = v.get("axis", Vector3.UP)
			var half := maxf(float(v["h"]) * 0.5 - float(v["r"]), 0.0)
			var t := clampf(q.dot(ax), -half, half)
			return (q - ax * t).length() - float(v["r"])
		"box":
			var rc: float = v["rc"]
			var b: Vector3 = (v["half"] as Vector3) - Vector3(rc, rc, rc)
			var d := q.abs() - b
			return Vector3(maxf(d.x, 0.0), maxf(d.y, 0.0), maxf(d.z, 0.0)).length() + minf(maxf(d.x, maxf(d.y, d.z)), 0.0) - rc
	return 9.0


## What FighterRig used to build (bone-local), for the "old vs new" report. Needs the live skeleton for rest offsets.
func _old_volumes(f: Fighter) -> Dictionary:
	var sk := f.rig.skeleton
	var out := {}
	out["head"] = {"bone": "head", "kind": "capsule", "off": Vector3(0, 0.03, 0.03), "h": 0.50, "r": 0.12}
	out["torso"] = {"bone": "abdomenUpper", "kind": "capsule", "off": Vector3(0, 0.15, 0), "h": 0.62, "r": 0.19}
	for side in ["l", "r"]:
		var hand := "%sHand" % side
		var off: Vector3 = f.rig._rest_offset(hand, "%sMid1" % side)
		out[hand + "_hit"] = {"bone": hand, "kind": "sphere", "off": off, "r": 0.09}
		out[hand + "_guard"] = {"bone": hand, "kind": "sphere", "off": off, "r": 0.12}
		var fa := "%sForearmBend" % side
		var d: Vector3 = f.rig._rest_offset(fa, hand)
		out[fa] = {"bone": fa, "kind": "capsule", "off": d * 0.5, "axis": d.normalized(), "h": d.length() + 0.075 * 1.2, "r": 0.075}
	return out


func _surface_samples(v: Dictionary, n: int) -> Array:
	# points on the surface: march rays from the centre in fibonacci directions
	var pts := []
	var off: Vector3 = v["off"]
	for i in n:
		var y := 1.0 - 2.0 * (i + 0.5) / n
		var rr := sqrt(maxf(1.0 - y * y, 0.0))
		var th := PI * (1.0 + sqrt(5.0)) * i
		var dir := Vector3(cos(th) * rr, y, sin(th) * rr)
		var lo := 0.0
		var hi := 1.0
		for k in 18:
			var mid := (lo + hi) * 0.5
			if sdf(v, off + dir * mid) < 0.0:
				lo = mid
			else:
				hi = mid
		pts.append(off + dir * lo)
	return pts


## Mean / p95 distance from the volume's surface to the nearest mesh vertex, and the share of mesh vertices outside it (+1 cm).
func _eval(v: Dictionary, pts: Array) -> Dictionary:
	var stride := maxi(pts.size() / 1200, 1)
	var cloud := []
	for i in range(0, pts.size(), stride):
		cloud.append(pts[i])
	var ds := []
	for s in _surface_samples(v, 220):
		var best := 9.0
		for c in cloud:
			best = minf(best, (s as Vector3).distance_squared_to(c))
		ds.append(sqrt(best))
	var out_n := 0
	var vs := []
	for p in pts:
		var sd := sdf(v, p)
		vs.append(absf(sd))
		if sd > 0.01:
			out_n += 1
	var vmean := 0.0
	for x in vs:
		vmean += x
	vmean /= maxf(vs.size(), 1)
	var mean := 0.0
	for d in ds:
		mean += d
	return {"mean": mean / maxf(ds.size(), 1), "p95": _pct(ds, 0.95), "max": _pct(ds, 1.0), "vmean": vmean, "vp90": _pct(vs, 0.9), "outside": float(out_n) / maxf(pts.size(), 1)}


func _dims(v: Dictionary) -> String:
	match v["kind"]:
		"sphere":
			return "sphere r %.1f cm" % (float(v["r"]) * 100.0)
		"box":
			var h: Vector3 = v["half"]
			return "box %.1f x %.1f x %.1f cm (w x h x d)" % [h.x * 200.0, h.y * 200.0, h.z * 200.0]
		_:
			return "capsule r %.1f cm, %.1f cm tall" % [float(v["r"]) * 100.0, float(v["h"]) * 100.0]


func _report(id: String, fit: Dictionary, per_pose: Dictionary) -> Dictionary:
	var f: Fighter = await _spawn(id, "guard")
	var old := _old_volumes(f)
	var g: Dictionary = per_pose["guard"]["groups"]
	var xf: Dictionary = per_pose["guard"]["xf"]
	print("-- OLD volumes vs the visible mesh (guard pose): surface-to-mesh mean / p95 / max cm, mesh verts outside by > 1 cm")
	var rows := [
		["head", old["head"], "head", "head"],
		["torso", old["torso"], "chest+abdomen", "abdomenUpper"],
		["lHand hit", old["lHand_hit"], "hand_l", "lHand"],
		["lHand guard", old["lHand_guard"], "hand_l", "lHand"],
		["lForearm guard", old["lForearmBend"], "fore_l", "lForearmBend"],
	]
	for r in rows:
		var pts: Array
		if r[2] == "chest+abdomen":
			pts = _local(g["t_chest"] + g["t_abdomen"], xf[r[3]])
		else:
			pts = _local(g[r[2]], xf[r[3]])
		var e := _eval(r[1], pts)
		print("   %-15s %-34s sticks out: mean %.1f p95 %.1f max %.1f | mesh-to-volume |d| mean %.1f p90 %.1f | verts >1cm outside %.0f%%" % [r[0], _dims(r[1]), e["mean"] * 100, e["p95"] * 100, e["max"] * 100, e["vmean"] * 100, e["vp90"] * 100, e["outside"] * 100])
	print("-- NEW fit (guard) evaluated in every pose")
	var worst := 0.0
	for key in fit:
		var v: Dictionary = fit[key]
		var gk: String = {"head": "head", "neck": "neck", "chest": "t_chest", "abdomen": "t_abdomen", "lHand": "hand_l", "rHand": "hand_r", "lFist": "hand_l", "rFist": "hand_r", "lForearmBend": "fore_l", "rForearmBend": "fore_r"}[key]
		var line := "   %-13s %-40s" % [key, _dims(v)]
		for pose in POSES:
			var pg: Dictionary = per_pose[pose]["groups"]
			var px: Dictionary = per_pose[pose]["xf"]
			var e := _eval(v, _local(pg[gk], px[v["bone"]]))
			line += "  | %s out %.1f/%.1f mesh %.1f/%.1f >1cm %.0f%%" % [pose, e["mean"] * 100, e["p95"] * 100, e["vmean"] * 100, e["vp90"] * 100, e["outside"] * 100]
			if pose == "guard":
				worst = maxf(worst, e["p95"])
		print(line)
	return {}


func _fmt_v(v: Vector3) -> String:
	return "Vector3(%.4f, %.4f, %.4f)" % [v.x, v.y, v.z]


func _write_table(fits: Dictionary) -> void:
	var s := "class_name HitFit\nextends RefCounted\n## Per-model hit / hurt / guard volumes fitted to the visible mesh by tools/measure_hits.gd (do not edit by hand; rerun the tool with write=1).\n"
	s += "## Volumes are in the local frame of the named gameplay-skeleton bone. kind: capsule (along bone y) | box (rounded) | sphere.\n\nconst FIT := {\n"
	for id in fits:
		s += "\t\"%s\": {\n" % id
		for key in fits[id]:
			var v: Dictionary = fits[id][key]
			var line := "\t\t\"%s\": {\"bone\": \"%s\", \"kind\": \"%s\", \"off\": %s" % [key, v["bone"], v["kind"], _fmt_v(v["off"])]
			match v["kind"]:
				"capsule":
					line += ", \"axis\": %s, \"h\": %.4f, \"r\": %.4f" % [_fmt_v(v.get("axis", Vector3.UP)), v["h"], v["r"]]
				"box":
					line += ", \"half\": %s, \"rc\": %.4f" % [_fmt_v(v["half"]), v["rc"]]
				"sphere":
					line += ", \"r\": %.4f" % v["r"]
			s += line + "},\n"
		s += "\t},\n"
	s += "}\n"
	var fa := FileAccess.open("res://scripts/fighter/hit_fit.gd", FileAccess.WRITE)
	fa.store_string(s)
	fa.close()
	print("wrote scripts/fighter/hit_fit.gd")
