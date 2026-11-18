class_name HitAreas
extends RefCounted
## Collision layers and the Area3D classes used for hit detection.
##
## Layers (physics): 1 world, 2 fighter bodies, then per fighter index i (0/1):
##   hitbox  bit 2+i   (a fighter's striking limbs)       mask: foe hurt + foe guard
##   hurtbox bit 4+i   (head / torso / legs)
##   guard   bit 6+i   (gloves + forearms)
## The Area3D shapes are for the debug view only: hits are decided analytically (Hitbox.contact / Hurtbox.sdf below).
const LAYER_WORLD := 1 << 0
const LAYER_BODY := 1 << 1

## Contact rules (tests/test_hit_contact.gd, tools/measure_hits.gd): a blow registers only when the striking sphere (a glove, 5-7 cm)
## really intersects a target volume (a hull fitted to the visible body, scripts/fighter/hit_fit.gd) somewhere along its path since
## the last physics frame. The volumes are analytic (sphere / capsule / rounded box), so the sweep is exact at any fist speed.
const SWEEP_STEP := 0.012       ## m between samples along the glove's path (a fist covers up to ~12 cm per physics frame)
const TELEPORT := 0.6           ## m of travel in one frame that is an animation snap, not a punch: only the end point counts
const GLANCE_DEPTH := 0.01      ## penetration under this is a glancing blow (very low damage, a small flinch)
const TORSO_TOUCH := 0.01       ## torsos closer than this (m) are touching


static func hit_layer(index: int) -> int:
	return 1 << (2 + index)


static func hurt_layer(index: int) -> int:
	return 1 << (4 + index)


static func guard_layer(index: int) -> int:
	return 1 << (6 + index)


## Striking limb volume (attached to a hand/foot bone). One or more spheres (`shapes`: {node, r}); `radius` is the largest.
## Positions are the sphere centres (the fist), not the bone origin.
class Hitbox extends Area3D:
	var fighter: Node3D
	var limb := ""        ## "lHand", "rHand", "lFoot", "rFoot"
	var radius := 0.085
	var shapes: Array = []        ## {node: CollisionShape3D, r: float}
	var prev_pos := Vector3.ZERO  ## centre of shape 0 one physics frame ago
	var velocity := Vector3.ZERO  ## of shape 0
	var last_pos := Vector3.ZERO  ## centre of shape 0 now
	var _prev: Array = []
	var _cur: Array = []
	var _have_prev := false
	var clamp_delta := Vector3.ZERO   ## world shift the impact layer (impact_hold.gd) applied to this glove last tick: the sweeps use the path WITHOUT it

	func track(dt: float) -> void:
		if shapes.is_empty():
			return
		_prev = _cur.duplicate()
		_cur.clear()
		for sh in shapes:
			_cur.append((sh["node"] as CollisionShape3D).global_position - clamp_delta)
		if not _have_prev:
			_prev = _cur.duplicate()
		var p: Vector3 = _cur[0]
		prev_pos = _prev[0]
		if _have_prev and dt > 0.0:
			velocity = (p - prev_pos) / dt
		last_pos = p
		_have_prev = true

	func centre_now(i: int) -> Vector3:
		return _cur[i] if i < _cur.size() else global_position

	func centre_before(i: int) -> Vector3:
		return _prev[i] if i < _prev.size() else centre_now(i)

	## Swept contact of sphere `i` with the defender volume `hu`: the deepest penetration of the glove into it along last frame's
	## centre -> this frame's centre. {} when the glove never touched it.
	func contact(hu: Hurtbox, i: int) -> Dictionary:
		return HitAreas.sweep(centre_before(i), centre_now(i), float(shapes[i]["r"]), hu)


## Swept sphere (radius r, path a -> b) against a volume. {} = never touched, else {depth, point (on the volume skin, at first touch), centre
## (glove centre where it first touched), normal (outward, there), t (0 = a .. 1 = b)}. `depth` is the deepest penetration on the path.
static func sweep(a: Vector3, b: Vector3, r: float, hu: Hurtbox) -> Dictionary:
	var d := a.distance_to(b)
	var n := 1
	if d <= TELEPORT:
		n = clampi(int(ceil(d / SWEEP_STEP)), 1, 40)
	else:
		a = b
		d = 0.0
	if hu.sdf(a.lerp(b, 0.5)) - r > d * 0.5 + 1e-4:
		return {}   # even the nearest point of the path (half the path length from the middle) cannot reach it
	var best := -1.0
	var first_p := Vector3.ZERO
	var first_t := -1.0
	for k in range(0, n + 1):   # oldest first: the first sample inside is where the glove touched
		var t := float(k) / float(n)
		var p := a.lerp(b, t)
		var dep := r - hu.sdf(p)
		if dep >= 0.0 and first_t < 0.0:
			first_p = p
			first_t = t
		best = maxf(best, dep)
	if first_t < 0.0:
		return {}
	var nrm := hu.normal_at(first_p)
	return {"depth": best, "point": first_p - nrm * hu.sdf(first_p), "centre": first_p, "normal": nrm, "t": first_t}


## Target volume (head, torso / leg hull) or guard volume (is_guard) on the defender.
class Hurtbox extends Area3D:
	var fighter: Node3D
	var zone := "head"    ## "head" | "body" | "leg"
	var side := ""        ## "L" / "R" for legs
	var is_guard := false
	var shape_node: CollisionShape3D
	var corner := 0.0     ## > 0: the box shape is a rounded box with this corner radius
	var _inv := Transform3D.IDENTITY
	var _inv_frame := -1
	var limb := ""        ## bone the volume rides on (guards: "lHand", "rForearmBend", ...)
	var axis_extend := 0.0   ## m added to each end of the centre line for the "how centred" measure (head: a blow anywhere from chin to temple is centred)
	var _samples: Array = []

	## Contact samples in the shape's local frame: [[Vector3, radius]]. Boxes: points on the skin (radius 0); capsules / spheres:
	## points along the axis with the volume's radius.
	func samples() -> Array:
		if _samples.is_empty():
			var s := shape_node.shape
			if s is BoxShape3D:
				for p: Vector3 in HitAreas.hull_points((s as BoxShape3D).size * 0.5, corner):
					_samples.append([p, 0.0])
			elif s is CapsuleShape3D:
				var cs := s as CapsuleShape3D
				var half := maxf(cs.height * 0.5 - cs.radius, 0.0)
				for k in 4:
					_samples.append([Vector3(0, lerpf(-half, half, k / 3.0), 0), cs.radius])
			elif s is SphereShape3D:
				_samples.append([Vector3.ZERO, (s as SphereShape3D).radius])
		return _samples

	func _to_local(p: Vector3) -> Vector3:
		var f := Engine.get_physics_frames()
		if f != _inv_frame:
			var xf := shape_node.global_transform
			_inv = Transform3D(xf.basis.orthonormalized(), xf.origin).affine_inverse()
			_inv_frame = f
		return _inv * p

	## Signed distance (m) from world point p to the volume surface, negative inside. Exact for spheres, capsules, rounded boxes.
	func sdf(p: Vector3) -> float:
		var q := _to_local(p)
		var s := shape_node.shape
		if s is CapsuleShape3D:
			var cs := s as CapsuleShape3D
			q.y -= clampf(q.y, -maxf(cs.height * 0.5 - cs.radius, 0.0), maxf(cs.height * 0.5 - cs.radius, 0.0))
			return q.length() - cs.radius
		if s is SphereShape3D:
			return q.length() - (s as SphereShape3D).radius
		if s is BoxShape3D:
			var b := (s as BoxShape3D).size * 0.5 - Vector3(corner, corner, corner)
			var d := q.abs() - b
			return Vector3(maxf(d.x, 0.0), maxf(d.y, 0.0), maxf(d.z, 0.0)).length() + minf(maxf(d.x, maxf(d.y, d.z)), 0.0) - corner
		return 9.0

	## Outward unit normal at (or near) world point p (gradient of the distance field).
	func normal_at(p: Vector3) -> Vector3:
		var e := 0.004
		var g := Vector3(sdf(p + Vector3(e, 0, 0)) - sdf(p - Vector3(e, 0, 0)), sdf(p + Vector3(0, e, 0)) - sdf(p - Vector3(0, e, 0)), sdf(p + Vector3(0, 0, e)) - sdf(p - Vector3(0, 0, e)))
		return g.normalized() if g.length() > 1e-6 else Vector3.UP

	## Dimension used to normalise how centred a blow is.
	func reach() -> float:
		var s := shape_node.shape
		if s is SphereShape3D:
			return (s as SphereShape3D).radius
		if s is CapsuleShape3D:
			return (s as CapsuleShape3D).radius
		if s is BoxShape3D:
			var sz := (s as BoxShape3D).size
			return (sz.x + sz.z) * 0.25
		return 0.1

	## Point on the volume's centre line nearest to p (sphere: the centre; capsule / box: the axis segment).
	func axis_point(p: Vector3) -> Vector3:
		var xf := shape_node.global_transform
		var c := xf.origin
		var s := shape_node.shape
		var up := xf.basis.y.normalized()
		var half := 0.0
		if s is CapsuleShape3D:
			var cs := s as CapsuleShape3D
			half = maxf(cs.height * 0.5 - cs.radius, 0.0)
		elif s is BoxShape3D:
			half = (s as BoxShape3D).size.y * 0.5
		if half > 0.0 or axis_extend > 0.0:
			half += axis_extend
			c += up * clampf((p - c).dot(up), -half, half)
		return c

	## 0 = dead centre of the volume, 1 = grazing the surface (hit sphere of radius r at p).
	## With a travel velocity the ratio is the sideways miss distance of the volume's centre line from the strike line (how
	## centred the blow is); without one it is the plain centre distance.
	func contact_ratio(p: Vector3, r: float, vel := Vector3.ZERO) -> float:
		var off := axis_point(p) - p
		if vel.length() > 0.5:
			var vh := vel.normalized()
			off = off - vh * off.dot(vh)
		return clampf(off.length() / (reach() + r), 0.0, 1.0)


## Skin points of a rounded-box hull in its local frame: 3 height levels x (4 corner arcs x 2 + 4 face middles).
static func hull_points(h: Vector3, rc: float) -> Array:
	var pts: Array = []
	var inner := h - Vector3(rc, rc, rc)
	for y in [-h.y, 0.0, h.y]:
		var yy: float = clampf(y, -inner.y, inner.y)
		var rho := sqrt(maxf(rc * rc - (y - yy) * (y - yy), 0.0))
		for sx in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				for ang in [0.0, 90.0]:
					var a := deg_to_rad(ang)
					pts.append(Vector3(sx * (inner.x + rho * cos(a)), y, sz * (inner.z + rho * sin(a))))
		pts.append(Vector3(inner.x + rho, y, 0.0))
		pts.append(Vector3(-inner.x - rho, y, 0.0))
		pts.append(Vector3(0.0, y, inner.z + rho))
		pts.append(Vector3(0.0, y, -inner.z - rho))
	return pts


## Body contact between two fighters (scripts/fighter/body_contact.gd): the shortest distance (m) between a body part of one
## (torso hulls, head, and the arms / gloves unless that arm is punching) and the torso or head of the other, both ways. <= 0 = they
## overlap. Gloves against gloves do not count: guards meeting at arm's length is not a clinch.
static func contact_gap(a: Object, b: Object) -> float:
	var best := 9.0
	for pair in [[a, b], [b, a]]:
		var me: Object = pair[0]
		var targets: Array = pair[1].rig.contact_targets
		var skip := ""
		if me.state == me.State.ATTACK and not me.atk.is_empty():
			skip = String(me.atk["limb"]).substr(0, 1)   # the punching arm is a blow, not contact
		for hu: Hurtbox in me.rig.contact_sources:
			if skip != "" and hu.is_guard and hu.limb.begins_with(skip):
				continue
			var xf: Transform3D = hu.shape_node.global_transform
			for smp in hu.samples():
				var w: Vector3 = xf * (smp[0] as Vector3)
				var rr: float = smp[1]
				for hv: Hurtbox in targets:
					best = minf(best, hv.sdf(w) - rr)
	return best


## Shortest distance (m) between the two fighters' torso hulls only (<= 0 = the torsos overlap). Tests / diagnostics.
static func torso_gap(a: Object, b: Object) -> float:
	var best := 9.0
	for pair in [[a, b], [b, a]]:
		for hu: Hurtbox in pair[0].rig.torso:
			var xf: Transform3D = hu.shape_node.global_transform
			for smp in hu.samples():
				var w: Vector3 = xf * (smp[0] as Vector3)
				for hv: Hurtbox in pair[1].rig.torso:
					best = minf(best, hv.sdf(w))
	return best
