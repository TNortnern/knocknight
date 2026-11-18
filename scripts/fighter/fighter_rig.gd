class_name FighterRig
extends RefCounted
## Builds the hit/hurt/guard Area3Ds on BoneAttachment3Ds of a fighter's skeleton, plus the fist modifier.

var hitboxes: Array = []       ## HitAreas.Hitbox
var hurtboxes: Array = []      ## HitAreas.Hurtbox (non-guard)
var guards: Array = []         ## HitAreas.Hurtbox (is_guard)
var skeleton: Skeleton3D
var debug_meshes: Array = []
var torso: Array = []          ## HitAreas.Hurtbox: chest + abdomen hulls
var contact_targets: Array = []   ## torso + head hulls: what the other fighter's body can touch (HitAreas.contact_gap)
var contact_sources: Array = []   ## torso + head hulls + the arm / glove guard hulls: the parts that touch

const HitFitScript := preload("res://scripts/fighter/hit_fit.gd")
const HitFitVisScript := preload("res://scripts/fighter/hit_fit_vis.gd")   ## the same volumes fitted in the frames of the VISIBLE Meshy bones

var visible_mounted := false   ## true once the volumes ride the visible skeleton (rebind_visible)
var _reg := {}                 ## fit key ("head", "lFist", ...) -> the Hurtbox / Hitbox built from it

var _fighter: Node3D
var _index := 0


func build(fighter: Node3D, sk: Skeleton3D, index: int) -> void:
	_fighter = fighter
	skeleton = sk
	_index = index
	var fist := FistPose.new()
	fist.name = "FistPose"
	sk.add_child(fist)
	sk.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_PHYSICS
	var fit: Dictionary = HitFitScript.FIT.get(String(fighter.get("model")), {})
	if fit.is_empty():
		fit = HitFitScript.FIT.get("viper", {})
	# torso first: the "body" aim point of the punch pose is the first body hurtbox (the belly), see punch_pose.gd
	_hurt_hull(fit["abdomen"], "body", true, "abdomen")
	_hurt_hull(fit["chest"], "body", true, "chest")
	_hurt_hull(fit["head"], "head", false, "head")
	if fit.has("neck"):
		_hurt_hull(fit["neck"], "head", false, "neck")   # the throat is a head target too: the straights end at chin / throat height
	for side in ["l", "r"]:
		var hand := "%sHand" % side
		var fv: Dictionary = fit["%sFist" % side]
		_reg["%sFist" % side] = _hitbox(hand, fv["off"], fv["r"])
		_guard_hull(fit[hand], hand)
		_guard_hull(fit["%sForearmBend" % side], "%sForearmBend" % side)
		var foot := "%sFoot" % side
		var toe := _rest_offset(foot, "%sMetatarsals" % side)
		_hitbox(foot, toe, 0.09)
		_hitbox_extra(foot, Vector3(0, 0.16, 0.02), 0.075)
		var thigh := "%sThighBend" % side
		_hurt_capsule(thigh, Vector3(0, -0.21, 0.0), 0.46, 0.105, "leg", side.to_upper())
		var shin := "%sShin" % side
		_hurt_capsule(shin, Vector3(0, -0.20, 0.0), 0.44, 0.075, "leg", side.to_upper())


## A fitted volume (hit_fit.gd entry) as a hurtbox of `zone`. Boxes are rounded boxes (corner radius in Hurtbox.corner).
func _hurt_hull(v: Dictionary, zone: String, torso: bool, key: String) -> void:
	var hu := _hurt(_attachment(v["bone"]), zone, "", false)
	_reg[key] = hu
	hu.shape_node = _hull_shape(hu, v)
	if v["kind"] == "box":
		hu.corner = v["rc"]
	if zone == "head":
		hu.axis_extend = 0.08
	hu.limb = v["bone"]
	hurtboxes.append(hu)
	contact_targets.append(hu)
	contact_sources.append(hu)
	if torso:
		self.torso.append(hu)


func _guard_hull(v: Dictionary, key: String) -> void:
	var hu := _hurt(_attachment(v["bone"]), "guard", "", true)
	_reg["guard_" + key] = hu
	hu.shape_node = _hull_shape(hu, v)
	hu.limb = v["bone"]
	guards.append(hu)
	contact_sources.append(hu)


func _hull_shape(a: Area3D, v: Dictionary) -> CollisionShape3D:
	match v["kind"]:
		"sphere":
			var cs := _sphere_shape(a, v["off"], v["r"])
			return cs
		"box":
			var cs2 := CollisionShape3D.new()
			var sh := BoxShape3D.new()
			sh.size = (v["half"] as Vector3) * 2.0
			cs2.shape = sh
			cs2.position = v["off"]
			a.add_child(cs2)
			return cs2
	return _capsule_shape(a, v["off"], v["h"], v["r"], v.get("axis", Vector3.UP))


func _rest_offset(from_bone: String, to_bone: String) -> Vector3:
	var a := skeleton.find_bone(from_bone)
	var b := skeleton.find_bone(to_bone)
	if a < 0 or b < 0:
		return Vector3.ZERO
	var ra := skeleton.get_bone_global_rest(a)
	var rb := skeleton.get_bone_global_rest(b)
	return (ra.affine_inverse() * rb).origin


func _attachment(bone: String) -> BoneAttachment3D:
	var ba := BoneAttachment3D.new()
	ba.name = "BA_%s_%d" % [bone, skeleton.get_child_count()]
	ba.bone_name = bone
	skeleton.add_child(ba)
	return ba


func _sphere_shape(a: Area3D, off: Vector3, r: float) -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = r
	cs.shape = sh
	cs.position = off
	a.add_child(cs)
	return cs


func _hitbox(bone: String, off: Vector3, r: float) -> HitAreas.Hitbox:
	var ba := _attachment(bone)
	var hb := HitAreas.Hitbox.new()
	hb.name = "Hit_" + bone
	hb.fighter = _fighter
	hb.limb = bone
	hb.radius = r
	hb.collision_layer = HitAreas.hit_layer(_index)
	hb.collision_mask = HitAreas.hurt_layer(1 - _index) | HitAreas.guard_layer(1 - _index)
	hb.monitoring = false   # hits are decided analytically (HitAreas.sweep); the shapes are for the debug view and the sweep path
	hb.monitorable = false
	ba.add_child(hb)
	var cs := _sphere_shape(hb, off, r)
	hb.shapes.append({"node": cs, "r": r})
	hitboxes.append(hb)
	return hb


func _hitbox_extra(bone: String, off: Vector3, r: float) -> void:
	for hb in hitboxes:
		if hb.limb == bone:
			var cs := _sphere_shape(hb, off, r)
			hb.shapes.append({"node": cs, "r": r})
			hb.radius = maxf(hb.radius, r)


func _hurt(ba: BoneAttachment3D, zone: String, side: String, guard: bool) -> HitAreas.Hurtbox:
	var hu := HitAreas.Hurtbox.new()
	hu.name = ("Guard_" if guard else "Hurt_") + zone + side
	hu.fighter = _fighter
	hu.zone = zone
	hu.side = side
	hu.is_guard = guard
	hu.collision_layer = HitAreas.guard_layer(_index) if guard else HitAreas.hurt_layer(_index)
	hu.collision_mask = 0
	hu.monitoring = false
	hu.monitorable = true
	ba.add_child(hu)
	return hu


func _hurt_sphere(bone: String, off: Vector3, r: float, zone: String, side: String) -> void:
	var hu := _hurt(_attachment(bone), zone, side, false)
	hu.shape_node = _sphere_shape(hu, off, r)
	hurtboxes.append(hu)


func _capsule_shape(a: Area3D, off: Vector3, height: float, r: float, dir := Vector3.UP) -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	var sh := CapsuleShape3D.new()
	sh.radius = r
	sh.height = maxf(height, r * 2.0 + 0.001)
	cs.shape = sh
	cs.position = off
	if dir.dot(Vector3.UP) < 0.999:
		cs.basis = Basis(Quaternion(Vector3.UP, dir.normalized()))
	a.add_child(cs)
	return cs


func _hurt_capsule(bone: String, off: Vector3, height: float, r: float, zone: String, side: String) -> void:
	var hu := _hurt(_attachment(bone), zone, side, false)
	hu.shape_node = _capsule_shape(hu, off, height, r)
	hurtboxes.append(hu)


func _guard_sphere(bone: String, off: Vector3, r: float) -> void:
	var hu := _hurt(_attachment(bone), "guard", "", true)
	hu.shape_node = _sphere_shape(hu, off, r)
	guards.append(hu)


## Capsule from the bone origin along `delta` (bone-local), centred at `centre`.
func _guard_capsule(bone: String, centre: Vector3, delta: Vector3, r: float, _label: String) -> void:
	var hu := _hurt(_attachment(bone), "guard", "", true)
	hu.shape_node = _capsule_shape(hu, centre, delta.length() + r * 1.2, r, delta)
	guards.append(hu)


func hitbox_for(limb: String) -> Array:
	var out: Array = []
	for hb in hitboxes:
		if hb.limb == limb:
			out.append(hb)
	return out


## Hit detection on what the player sees. The volumes above are built on the hidden M3DMale gameplay skeleton and fitted to the Meshy skin
## in the guard pose; the retarget (meshy_skin.gd) only matches rotations, so the moment the pose changes (a punch, a slip, a lean) the
## skin and the volumes part by up to several cm. Here every fitted volume is re-mounted on the VISIBLE Meshy bone it was fitted against
## (hit_fit_vis.gd, tools/fit_visible.gd), so the glove sphere, the head / torso hulls and the gloves are the skin's own rigid parts.
## `ms` = the MeshySkin node. No-op without a table for this model.
func rebind_visible(ms: Node, model: String) -> void:
	var fit: Dictionary = HitFitVisScript.FIT.get(model, {})
	if fit.is_empty():
		return
	for key in fit:
		var v: Dictionary = fit[key]
		var mount: Node3D = ms.mount(v["bone"])
		var node: Area3D = null
		var is_guard := false
		if key.ends_with("Fist"):
			node = _reg.get(key)
		elif key in ["lHand", "rHand", "lForearmBend", "rForearmBend"]:
			node = _reg.get("guard_" + key)
			is_guard = true
		else:
			node = _reg.get(key)
		if node == null:
			continue
		var old_parent := node.get_parent()
		old_parent.remove_child(node)
		mount.add_child(node)
		node.transform = Transform3D.IDENTITY
		node.set_meta("vis_mount", true)
		if node is HitAreas.Hitbox:
			var hb := node as HitAreas.Hitbox
			for sh in hb.shapes:
				(sh["node"] as Node).queue_free()
			hb.shapes.clear()
			var cs := _sphere_shape(hb, v["off"], v["r"])
			hb.shapes.append({"node": cs, "r": v["r"]})
			hb.radius = v["r"]
			hb._have_prev = false
			hb._cur.clear()
			hb._prev.clear()
			continue
		var hu := node as HitAreas.Hurtbox
		hu.shape_node.queue_free()
		hu.remove_child(hu.shape_node)
		hu.shape_node = _hull_shape(hu, v)
		if v["kind"] == "box":
			hu.corner = v["rc"]
			hu.shape_node.basis = Basis(v.get("q", Quaternion.IDENTITY) as Quaternion)
		hu._samples = []
		hu._inv_frame = -1
		if old_parent is BoneAttachment3D and old_parent.get_child_count() == 0:
			old_parent.queue_free()
	visible_mounted = true


## World centre of the volume a blow of `zone` is aimed at (head: the head hull, body: the chest hull); Vector3.INF if there is none.
func target_centre(zone: String) -> Vector3:
	var hu = _reg.get("head" if zone == "head" else "chest")
	if hu == null or hu.shape_node == null:
		return Vector3.INF
	return hu.shape_node.global_position
