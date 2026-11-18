extends RefCounted
## T-pose probe for one fighter. Connects to the logic (M3DMale) skeleton's `skeleton_updated`, i.e. samples the FINAL pose
## (after pose layers, ragdoll simulator and ragdoll blend), and for Meshy fighters also reads the visible Meshy skeleton.
## driver_deg / meshy_deg = mean angle (deg) between the final local rotation of the arm / leg / spine bones and their rest
## rotation: ~0 means the body stands in the rig's rest (T) pose, a guard / fall / lying pose is far from it.
## Preloaded by tools/detect_tpose.gd and tests/test_no_tpose.gd.

const DRIVER_BONES := ["lShldrBend", "rShldrBend", "lForearmBend", "rForearmBend", "lThighBend", "rThighBend",
	"abdomenLower", "chestUpper", "neckLower", "head", "lShin", "rShin"]
const MESHY_BONES := ["LeftArm", "RightArm", "LeftForeArm", "RightForeArm", "LeftUpLeg", "RightUpLeg",
	"Spine02", "Spine", "neck", "Head", "LeftLeg", "RightLeg"]
const LEG_BONES := ["lThighBend", "rThighBend", "lShin", "rShin"]
const MESHY_LEG_BONES := ["LeftUpLeg", "RightUpLeg", "LeftLeg", "RightLeg"]
const LEG_T_DEG := 11.0   ## legs straight in the rest pose measure ~8 deg; the lowest guard / walk stance is ~14
const T_DEG := 10.0            ## below this the pose counts as the rest pose

var fighter: Fighter
var sk: Skeleton3D
var msk: Skeleton3D
var legs_deg := 99.0             ## same for the legs only (the upper body can be guard-posed while the legs stand in the rest pose)
var meshy_legs_deg := 99.0
var driver_deg := 99.0
var meshy_deg := 99.0
var stamp := -1                  ## Engine.get_physics_frames() of the last driver sample
var _didx: Array = []
var _midx: Array = []
var _lidx: Array = []
var _mlidx: Array = []
var run_frames := 0              ## consecutive frames in the rest pose (driver or Meshy skeleton)
var worst_run := 0
var worst_info := ""
var frames := 0


static func make(f: Fighter) -> RefCounted:
	var p: RefCounted = (load("res://tools/tpose_probe.gd") as GDScript).new()
	p.call("_init_for", f)
	return p


func _init_for(f: Fighter) -> void:
	fighter = f
	sk = f.rig.skeleton
	for b in DRIVER_BONES:
		_didx.append(sk.find_bone(b))
	for b in LEG_BONES:
		_lidx.append(sk.find_bone(b))
	if f.meshy_skin != null:
		for b in MESHY_LEG_BONES:
			_mlidx.append(f.meshy_skin.skeleton.find_bone(b))
		msk = f.meshy_skin.skeleton
		for b in MESHY_BONES:
			_midx.append(msk.find_bone(b))
	sk.skeleton_updated.connect(_on_updated)


static func _mean_dev(s: Skeleton3D, idx: Array) -> float:
	var tot := 0.0
	var n := 0
	for i: int in idx:
		if i < 0:
			continue
		var q := s.get_bone_pose_rotation(i)
		var r := s.get_bone_rest(i).basis.get_rotation_quaternion()
		tot += rad_to_deg(q.angle_to(r))
		n += 1
	return tot / maxf(n, 1)


func _on_updated() -> void:
	driver_deg = _mean_dev(sk, _didx)
	legs_deg = _mean_dev(sk, _lidx)
	stamp = Engine.get_physics_frames()
	if msk != null:
		meshy_deg = _mean_dev(msk, _midx)
		meshy_legs_deg = _mean_dev(msk, _mlidx)   # the Meshy sync (connected earlier) has already written its pose


func is_tpose() -> bool:
	if driver_deg < T_DEG or (msk != null and meshy_deg < T_DEG):
		return true
	if fighter.state == Fighter.State.WIN:
		return false   # a victory clip may stand with straight legs; the whole body is far from the rest pose
	return legs_deg < LEG_T_DEG or (msk != null and meshy_legs_deg < LEG_T_DEG)


## Call once per physics frame.
func step() -> void:
	frames += 1
	if is_tpose():
		run_frames += 1
		if run_frames > worst_run:
			worst_run = run_frames
			worst_info = "state=%s drv=%.1f meshy=%.1f ragdoll_active=%s tree=%s blend=%.2f" % [fighter.state_name, driver_deg, meshy_deg,
				str(fighter._ragdoll.active), str(fighter.anim.tree.active), fighter._ragdoll.blend.weight]
	else:
		run_frames = 0
