extends RefCounted
## The fighter's own body volumes (the HitFit hulls fitted to the visible mesh), evaluated straight from a Skeleton3D, in skeleton
## space. Used by the defence layers to keep the guard hands, forearms and elbows OUTSIDE the fighter's own torso and head, and by
## tools/capture_defence_play.gd to measure self-penetration. Preload this script, don't reference it by class name.
##
## A volume is {c: centre, ax: unit axis (capsules), h: total height, r: radius, half: box half extents, basis: bone basis, rc: corner}.

const HitFitScript := preload("res://scripts/fighter/hit_fit.gd")
const TORSO := ["chest", "abdomen"]
const ARM := {"l": ["lForearmBend", "lHand"], "r": ["rForearmBend", "rHand"]}


## All hull volumes of `model` posed on `sk` (names as in HitFit.FIT). Skeleton space.
static func build(sk: Skeleton3D, model: String) -> Dictionary:
	var out := {}
	var fit: Dictionary = HitFitScript.FIT.get(model, {})
	for k in fit:
		var d: Dictionary = fit[k]
		var bi := sk.find_bone(String(d["bone"]))
		if bi < 0:
			continue
		var g := sk.get_bone_global_pose(bi)
		var v := {"kind": d["kind"], "c": g * (d["off"] as Vector3), "basis": g.basis.orthonormalized()}
		match String(d["kind"]):
			"capsule":
				v["ax"] = (g.basis.orthonormalized() * (d["axis"] as Vector3)).normalized()
				v["h"] = d["h"]
				v["r"] = d["r"]
			"box":
				v["half"] = d["half"]
				v["rc"] = d["rc"]
			"sphere":
				v["r"] = d["r"]
		out[k] = v
	return out


## Signed distance (m, negative inside) from skeleton-space point p to a volume.
static func sdf(v: Dictionary, p: Vector3) -> float:
	match String(v["kind"]):
		"capsule":
			var half := maxf(float(v["h"]) * 0.5 - float(v["r"]), 0.0)
			var ax: Vector3 = v["ax"]
			var t := clampf((p - (v["c"] as Vector3)).dot(ax), -half, half)
			return p.distance_to((v["c"] as Vector3) + ax * t) - float(v["r"])
		"sphere":
			return p.distance_to(v["c"]) - float(v["r"])
		"box":
			var q: Vector3 = (v["basis"] as Basis).inverse() * (p - (v["c"] as Vector3))
			var rc: float = v["rc"]
			var b: Vector3 = (v["half"] as Vector3) - Vector3(rc, rc, rc)
			var d := q.abs() - b
			return Vector3(maxf(d.x, 0.0), maxf(d.y, 0.0), maxf(d.z, 0.0)).length() + minf(maxf(d.x, maxf(d.y, d.z)), 0.0) - rc
	return 9.0


## Outward gradient of the distance field at p (unit).
static func normal(v: Dictionary, p: Vector3) -> Vector3:
	var e := 0.004
	var g := Vector3(sdf(v, p + Vector3(e, 0, 0)) - sdf(v, p - Vector3(e, 0, 0)),
			sdf(v, p + Vector3(0, e, 0)) - sdf(v, p - Vector3(0, e, 0)),
			sdf(v, p + Vector3(0, 0, e)) - sdf(v, p - Vector3(0, 0, e)))
	return g.normalized() if g.length() > 1e-6 else Vector3.UP


## Sample points of an arm limb volume: [[point, radius]] (hand: the glove capsule + the fist sphere; forearm: along its axis).
static func limb_samples(v: Dictionary, count := 4) -> Array:
	var out: Array = []
	if String(v["kind"]) == "sphere":
		out.append([v["c"], float(v["r"])])
	elif String(v["kind"]) == "capsule":
		var half := maxf(float(v["h"]) * 0.5 - float(v["r"]), 0.0)
		for k in count:
			var t := lerpf(-half, half, float(k) / float(count - 1))
			out.append([(v["c"] as Vector3) + (v["ax"] as Vector3) * t, float(v["r"])])
	return out


## Deepest overlap (m, >= 0) of the arm limb samples of one side with the torso hulls (and the head when `head` is set).
## Returns {torso, head, forearm_torso, glove_torso} so a tool can tell the glove from the forearm.
static func arm_penetration(vols: Dictionary, side: String) -> Dictionary:
	var res := {"torso": 0.0, "head": 0.0, "forearm_torso": 0.0, "glove_torso": 0.0}
	var names: Array = ARM[side]
	var parts := [[names[0], "forearm"], [names[1], "glove"], [side + "Fist", "glove"]]
	for part in parts:
		if not vols.has(part[0]):
			continue
		for smp in limb_samples(vols[part[0]]):
			var p: Vector3 = smp[0]
			var r: float = smp[1]
			for tn in TORSO:
				if vols.has(tn):
					var dep := r - sdf(vols[tn], p)
					if dep > 0.0:
						res["torso"] = maxf(res["torso"], dep)
						var key := "forearm_torso" if part[1] == "forearm" else "glove_torso"
						res[key] = maxf(res[key], dep)
			if vols.has("head"):
				res["head"] = maxf(res["head"], r - sdf(vols["head"], p))
	res["head"] = maxf(res["head"], 0.0)
	return res


## Push a point (a glove centre / elbow) of radius `r` out of the torso hulls and head, by `margin` extra. Returns the moved point.
static func push_out(vols: Dictionary, p: Vector3, r: float, margin := 0.004, with_head := true) -> Vector3:
	var names: Array = TORSO.duplicate()
	if with_head:
		names.append("head")
	for _i in 3:
		var moved := false
		for n in names:
			if not vols.has(n):
				continue
			var d := sdf(vols[n], p) - r - margin
			if d < 0.0:
				p += normal(vols[n], p) * (-d)
				moved = true
		if not moved:
			break
	return p
