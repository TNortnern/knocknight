extends Node
## Meshy skin driver. The M3DMale skeleton stays the logical body (animation, pose layers, hit areas, ragdoll all keep
## writing to it); this node copies its FINAL pose onto a separate 24-joint Meshy skeleton every physics tick. Port of the
## web build's meshy.js: per mapped joint  targetWorld = driverWorld * inverse(driverRest) * targetRest  (fighter frame),
## parent before child, plus the hip translation offset.
## It runs from the driver skeleton's `skeleton_updated` signal: the Skeleton3D only holds the FINAL pose (pose layers,
## PhysicalBoneSimulator ragdoll, ragdoll blend) inside that signal, outside it get_bone_global_pose() is the plain
## animation pose again. So there is no frame lag and ragdoll poses are followed too.
## Preload this script, don't reference it by class name.

## Meshy joint -> M3DMale bone. Order = parent before child.
const MAP := [
	["Hips", "hip"], ["Spine02", "abdomenLower"], ["Spine01", "abdomenUpper"], ["Spine", "chestUpper"],   # Meshy chain: Hips > Spine02 > Spine01 > Spine
	["neck", "neckLower"], ["Head", "head"],
	["LeftShoulder", "lCollar"], ["LeftArm", "lShldrBend"], ["LeftForeArm", "lForearmBend"], ["LeftHand", "lHand"],
	["RightShoulder", "rCollar"], ["RightArm", "rShldrBend"], ["RightForeArm", "rForearmBend"], ["RightHand", "rHand"],
	["LeftUpLeg", "lThighBend"], ["LeftLeg", "lShin"], ["LeftFoot", "lFoot"], ["LeftToeBase", "lMetatarsals"],
	["RightUpLeg", "rThighBend"], ["RightLeg", "rShin"], ["RightFoot", "rFoot"], ["RightToeBase", "rMetatarsals"],
]
## Meshy joints whose offset from their parent is rescaled to the M3DMale segment length (arm reach matches the hit boxes).
const FIT_SEGMENTS := ["LeftForeArm", "LeftHand", "RightForeArm", "RightHand"]

var fighter: Node3D
var driver: Skeleton3D          ## M3DMale skeleton (logical body)
var skeleton: Skeleton3D        ## Meshy skeleton (visual)
var root: Node3D                ## instanced Meshy glb
var fit_limbs := true

var _joints: Array = []         ## {t: bone idx, d: bone idx, tp: parent joint index or -1, drest, trest: Quaternion, name}
var _skin_scale := 1.0
var _d_hip_rest := Vector3.ZERO         ## driver hip rest, fighter frame
var _t_hip_rest_local := Vector3.ZERO   ## Meshy hips rest origin, skeleton space
var _hip_scale := Vector3.ONE
var _hip_joint := 0
var _sm_inv := Quaternion.IDENTITY
var _pins: Array = []           ## joint indices pinned to the driver's joint position
const PIN_JOINTS := ["neck", "LeftArm", "RightArm"]
## Spine fit: the Meshy chain (Hips > Spine02 > Spine01 > Spine) has three bones at other heights than the four M3DMale trunk bones, so copying
## the rotations puts the neck base up to 18 cm away from the driver's (a deep duck). The old fix was to drag the neck joint there (pin), which
## stretched the visible neck to twice its length. Now the spine bones themselves are bent (CCD, a few degrees each, lengths kept) until the
## neck base is where the driver's is; only what the fit cannot reach is pinned.
const SPINE_FIT := ["Spine", "Spine01", "Spine02"]   ## tip first
const FIT_ITERATIONS := 8
const FIT_STEP_DEG := 12.0
const FIT_MAX_DEG := 38.0     ## total extra bend allowed per spine bone
const PIN_MAX := 0.2           ## m, largest shift of a pinned joint from its rest offset
var fit_error := 0.0             ## m the Meshy neck joint was off the driver's before / after the spine fit (diagnostic, skeleton units)
var fit_error_after := 0.0
var _fit_ids: Array = []
var _fit_neck := -1
var pin_shift := {}              ## Meshy joint name -> metres the pin moved it from its rest offset on the last sync (diagnostic)
var _snap := {}                 ## driver bone name -> world Transform3D of the last sync (tests / tools)
var _host: Node3D               ## the fighter's ModelSlot (the mounts are children of it)
var _mounts := {}               ## Meshy joint name -> {node: Node3D, idx: bone index}: unit-scale frames riding the VISIBLE bones (see mount())
const SNAP_BONES := ["head", "lHand", "rHand", "lMetatarsals", "rMetatarsals", "hip"]


## `host` is the node the skin is added to (the fighter's ModelSlot); `drv` the M3DMale skeleton.
static func attach(p_fighter: Node3D, host: Node3D, drv: Skeleton3D, glb_path: String) -> Node:
	var ms: Node = (load("res://scripts/fighter/meshy_skin.gd") as GDScript).new()
	ms.name = "MeshySkin"
	ms.set("fighter", p_fighter)
	ms.set("driver", drv)
	host.add_child(ms)
	ms.call("_build", host, glb_path)
	return ms


func _build(host: Node3D, glb_path: String) -> void:
	_host = host
	root = (load(glb_path) as PackedScene).instantiate()
	root.name = "MeshyModel"
	for ap in root.find_children("*", "AnimationPlayer", true, false):   # the export's baked walk clip; we drive the bones
		ap.get_parent().remove_child(ap)
		ap.free()
	host.add_child(root)
	skeleton = root.find_child("Skeleton3D", true, false)
	var fxf_inv := fighter.global_transform.affine_inverse()
	var d_xf: Transform3D = fxf_inv * driver.global_transform
	# scale: Meshy head joint at the M3DMale head joint's height
	var d_head_y: float = (d_xf * driver.get_bone_global_rest(driver.find_bone("head")).origin).y
	var t_head_y := (skeleton.get_bone_global_rest(skeleton.find_bone("Head")).origin * 0.01).y   # skeleton is in cm under a 0.01 Armature
	_skin_scale = d_head_y / t_head_y
	root.scale = Vector3.ONE * _skin_scale
	_d_hip_rest = d_xf * driver.get_bone_global_rest(driver.find_bone("hip")).origin
	_t_hip_rest_local = skeleton.get_bone_global_rest(skeleton.find_bone("Hips")).origin
	# centre the model on the driver's hips (x / z); the sole stays on y = 0
	var sk_xf := fxf_inv * skeleton.global_transform
	var t_hip := sk_xf * _t_hip_rest_local
	root.position = Vector3(_d_hip_rest.x - t_hip.x, 0.0, _d_hip_rest.z - t_hip.z)
	sk_xf = fxf_inv * skeleton.global_transform
	# leg-length ratio scales the hip's vertical travel so crouches keep the feet planted
	var d_ankle := (d_xf * driver.get_bone_global_rest(driver.find_bone("lFoot")).origin).y
	var t_ankle := (sk_xf * skeleton.get_bone_global_rest(skeleton.find_bone("LeftFoot")).origin).y
	_hip_scale = Vector3(1.0, (t_hip.y - t_ankle) / maxf(_d_hip_rest.y - d_ankle, 0.1), 1.0)
	var sm_rot := sk_xf.basis.orthonormalized().get_rotation_quaternion()   # Meshy skeleton frame in the fighter frame
	_sm_inv = sm_rot.inverse()
	var by_name := {}
	for k in MAP.size():
		var tn: String = MAP[k][0]
		var ti := skeleton.find_bone(tn)
		var di := driver.find_bone(MAP[k][1])
		assert(ti >= 0 and di >= 0, "meshy retarget joint " + tn)
		var drest := (d_xf.basis.orthonormalized() * driver.get_bone_global_rest(di).basis.orthonormalized()).get_rotation_quaternion()
		var trest := sm_rot * skeleton.get_bone_global_rest(ti).basis.orthonormalized().get_rotation_quaternion()
		var tp := -1
		var pb := skeleton.get_bone_parent(ti)
		if pb >= 0 and by_name.has(skeleton.get_bone_name(pb)):
			tp = by_name[skeleton.get_bone_name(pb)]
		by_name[tn] = k
		_joints.append({"t": ti, "d": di, "tp": tp, "drest": drest, "trest": trest, "name": tn})
		if tn == "Hips":
			_hip_joint = k
	for k in _joints.size():
		if PIN_JOINTS.has(_joints[k]["name"]):
			_pins.append(k)
	if fit_limbs:
		_fit_segments(d_xf)
		_align_arm_rest(sm_rot, d_xf)
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).extra_cull_margin = 2.0
	driver.skeleton_updated.connect(sync)
	sync()


## Elbow / wrist offsets rescaled so the Meshy arm is as long as the M3DMale arm (the hit boxes follow that one).
func _fit_segments(d_xf: Transform3D) -> void:
	var cm_to_fighter := (fighter.global_transform.affine_inverse() * skeleton.global_transform).basis.get_scale().x
	for j in _joints:
		if not FIT_SEGMENTS.has(j["name"]) or j["tp"] < 0:
			continue
		var pj: Dictionary = _joints[j["tp"]]
		var ld: float = ((d_xf * driver.get_bone_global_rest(j["d"]).origin) - (d_xf * driver.get_bone_global_rest(pj["d"]).origin)).length()
		var local_o := skeleton.get_bone_rest(j["t"]).origin
		var lt := local_o.length() * cm_to_fighter
		var k := clampf(ld / maxf(lt, 0.001), 0.8, 1.25)
		skeleton.set_bone_pose_position(j["t"], local_o * k)


## Meshy's rest pose is a slight A-pose, M3DMale's an exact T-pose. The delta retarget keeps that offset, which puts the
## wrists a few cm off the hit boxes. Rotate each arm joint's target rest so its bone points exactly where the driver's does.
func _align_arm_rest(sm_rot: Quaternion, d_xf: Transform3D) -> void:
	var by_name := {}
	for k in _joints.size():
		by_name[_joints[k]["name"]] = k
	var d_rot := d_xf.basis.orthonormalized()
	for side in ["Left", "Right"]:
		var adj := {}
		for pair in [["Arm", "ForeArm"], ["ForeArm", "Hand"]]:
			var a: Dictionary = _joints[by_name[side + pair[0]]]
			var b: Dictionary = _joints[by_name[side + pair[1]]]
			var dt: Vector3 = sm_rot * (skeleton.get_bone_global_rest(b["t"]).origin - skeleton.get_bone_global_rest(a["t"]).origin)
			var dd: Vector3 = d_rot * (driver.get_bone_global_rest(b["d"]).origin - driver.get_bone_global_rest(a["d"]).origin)
			var q := Quaternion(dt.normalized(), dd.normalized())
			adj[pair[0]] = q
			a["trest"] = q * (a["trest"] as Quaternion)
		var h: Dictionary = _joints[by_name[side + "Hand"]]
		h["trest"] = (adj["ForeArm"] as Quaternion) * (h["trest"] as Quaternion)


func skin_scale() -> float:
	return _skin_scale


## Copy the driver's current pose onto the Meshy skeleton (fighter frame, parent before child).
func sync() -> void:
	if driver == null or skeleton == null or not is_instance_valid(fighter) or not fighter.is_inside_tree():
		return
	var fxf_inv := fighter.global_transform.affine_inverse()
	var d_xf: Transform3D = fxf_inv * driver.global_transform
	var d_rot := d_xf.basis.orthonormalized()
	var dg := driver.global_transform
	for b: String in SNAP_BONES:
		_snap[b] = dg * driver.get_bone_global_pose(driver.find_bone(b))
	var g := []   # skeleton-space global rotation of every mapped Meshy joint
	g.resize(_joints.size())
	for k in _joints.size():
		var j: Dictionary = _joints[k]
		var gp := driver.get_bone_global_pose(j["d"])
		var rd := (d_rot * gp.basis.orthonormalized()).get_rotation_quaternion()
		var q: Quaternion = rd * (j["drest"] as Quaternion).inverse() * (j["trest"] as Quaternion)
		var gq: Quaternion = _sm_inv * q
		g[k] = gq
		var par := Quaternion.IDENTITY
		if j["tp"] >= 0:
			par = g[j["tp"]]
		skeleton.set_bone_pose_rotation(j["t"], (par.inverse() * gq).normalized())
	# hips: the driver's displacement from its rest, mapped onto the Meshy hips (cm skeleton space)
	var hj: Dictionary = _joints[_hip_joint]
	var d_hip := d_xf * driver.get_bone_global_pose(hj["d"]).origin
	var delta := (d_hip - _d_hip_rest) * _hip_scale
	var sk_basis := (fxf_inv * skeleton.global_transform).basis
	skeleton.set_bone_pose_position(hj["t"], _t_hip_rest_local + sk_basis.inverse() * delta)
	_fit_spine(g, dg)
	# pins: neck and shoulder sockets sit on the driver's joints (clamped), so a curled spine or a twisting torso cannot
	# carry the head / arms away from the hurt boxes (the Meshy spine has 3 joints at other heights than M3DMale's 4)
	var sk_inv := skeleton.global_transform.affine_inverse()
	var max_shift := PIN_MAX / maxf(sk_basis.get_scale().x, 0.0001)   # metres -> skeleton units
	for pin in _pins:
		var pj: Dictionary = _joints[pin]
		var tgt: Vector3 = sk_inv * (dg * driver.get_bone_global_pose(pj["d"]).origin)
		var parent_g: Transform3D = skeleton.get_bone_global_pose(skeleton.get_bone_parent(pj["t"]))
		var rest_o: Vector3 = skeleton.get_bone_rest(pj["t"]).origin
		var local: Vector3 = parent_g.affine_inverse() * tgt
		var shifted := (local - rest_o).limit_length(max_shift)
		pin_shift[pj["name"]] = (local - rest_o).length() * sk_basis.get_scale().x
		skeleton.set_bone_pose_position(pj["t"], rest_o + shifted)
	for joint in _mounts:   # the volumes follow the bones just posed
		_update_mount(joint)


## A Node3D that rides the visible Meshy joint `joint` (orthonormal frame, metres; the skeleton itself is in cm under a scaled armature).
## This is where the hit / hurt / guard volumes live (fighter_rig.gd rebind_visible): the single source of truth for what the player sees.
## It is moved inside sync(), i.e. in the same `skeleton_updated` that poses the skin, so it never lags the mesh.
func mount(joint: String) -> Node3D:
	if _mounts.has(joint):
		return _mounts[joint]["node"]
	var n := Node3D.new()
	n.name = "Mount_" + joint
	_host.add_child(n)   # under the fighter's ModelSlot (not top level): when the fighter node is moved / teleported the volumes go with it, like a BoneAttachment3D
	_mounts[joint] = {"node": n, "idx": skeleton.find_bone(joint)}
	_update_mount(joint)
	return n


func _update_mount(joint: String) -> void:
	var m: Dictionary = _mounts[joint]
	var w: Transform3D = skeleton.global_transform * skeleton.get_bone_global_pose(int(m["idx"]))
	(m["node"] as Node3D).global_transform = Transform3D(w.basis.orthonormalized(), w.origin)


## CCD on the Meshy spine so its neck joint lands on the driver's neck joint without stretching anything (see SPINE_FIT).
func _fit_spine(g: Array, dg: Transform3D) -> void:
	if _fit_ids.is_empty():
		for nm in SPINE_FIT:
			for k in _joints.size():
				if _joints[k]["name"] == nm:
					_fit_ids.append(k)
		for k in _joints.size():
			if _joints[k]["name"] == "neck":
				_fit_neck = k
	if _fit_ids.size() != SPINE_FIT.size() or _fit_neck < 0:
		return
	var sk_inv := skeleton.global_transform.affine_inverse()
	var neck_bone: int = _joints[_fit_neck]["t"]
	var tgt: Vector3 = sk_inv * (dg * driver.get_bone_global_pose(_joints[_fit_neck]["d"]).origin)
	var orig := []
	for id in _fit_ids:
		orig.append(skeleton.get_bone_pose_rotation(_joints[id]["t"]))
	fit_error = (skeleton.get_bone_global_pose(neck_bone).origin - tgt).length()
	for it in FIT_ITERATIONS:
		for n in _fit_ids.size():
			var bi: int = _joints[_fit_ids[n]]["t"]
			var gp := skeleton.get_bone_global_pose(bi)
			var end := skeleton.get_bone_global_pose(neck_bone).origin
			var v1 := end - gp.origin
			var v2 := tgt - gp.origin
			if v1.length() < 1e-4 or v2.length() < 1e-4:
				continue
			var q := Quaternion(v1.normalized(), v2.normalized())
			var ang := q.get_angle()
			if ang < 1e-4:
				continue
			if ang > PI:
				ang = TAU - ang
			q = Quaternion(q.get_axis().normalized(), minf(ang, deg_to_rad(FIT_STEP_DEG)))
			var pb := skeleton.get_bone_parent(bi)
			var pg := skeleton.get_bone_global_pose(pb).basis.orthonormalized().get_rotation_quaternion() if pb >= 0 else Quaternion.IDENTITY
			var cur: Quaternion = skeleton.get_bone_pose_rotation(bi)
			var want: Quaternion = (pg.inverse() * q * pg * cur).normalized()
			var o: Quaternion = orig[n]
			var total := o.angle_to(want)
			if total > deg_to_rad(FIT_MAX_DEG):
				want = o.slerp(want, deg_to_rad(FIT_MAX_DEG) / total)
			skeleton.set_bone_pose_rotation(bi, want)
	fit_error_after = (skeleton.get_bone_global_pose(neck_bone).origin - tgt).length()
	# the bones above the fitted chain keep the driver's world orientation (head look, collars)
	var spine_tip: int = _joints[_fit_ids[0]]["t"]
	var sp_q := skeleton.get_bone_global_pose(spine_tip).basis.orthonormalized().get_rotation_quaternion()
	for k in _joints.size():
		if _joints[k]["tp"] == _fit_ids[0]:
			var gq: Quaternion = g[k]
			skeleton.set_bone_pose_rotation(_joints[k]["t"], (sp_q.inverse() * gq).normalized())


## World transform of a driver (M3DMale) bone as of the last sync, i.e. its final pose incl. pose layers / ragdoll.
func driver_world(bone: String) -> Transform3D:
	return _snap[bone]


## World position of a Meshy joint by Meshy name (tests / tools).
func joint_world(joint: String) -> Vector3:
	return skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone(joint)).origin
