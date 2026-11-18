extends SkeletonModifier3D
## Additive procedural body pose for the defence family, applied after the animation pass:
##   shell  - shoulder-roll guard: torso turned (lead shoulder forward and up to the chin), chin tucked, slight lean back
##   lean   - lateral lean of the torso/neck (head-tilt slip), + = towards the fighter's left
##   hinge  - extra forward waist hinge + knee load on top of the authored duck clip (deep roll)
##   roll_lean - lateral lean of the roll (lags the hinge, which gives the roll its U-shaped head path)
## Everything is rotated about bone origins in the fighter frame (x = fighter's left, y up, z towards the foe), so the head,
## and the head hurtbox on it, really move. DefenceMoves owns the envelopes and writes the fields below each tick.

const D := PI / 180.0

var fighter: Node3D
var shell := 0.0
var lean := 0.0
var hinge := 0.0
var roll_lean := 0.0

# bone chains: [bone, share]
const TRUNK := [["abdomenLower", 0.30], ["abdomenUpper", 0.30], ["chestLower", 0.22], ["chestUpper", 0.18]]
const NECK := [["neckLower", 0.5], ["neckUpper", 0.5]]


func _process_modification_with_delta(_delta: float) -> void:
	var sk := get_skeleton()
	if sk == null or fighter == null:
		return
	if absf(shell) < 0.002 and absf(lean) < 0.002 and hinge < 0.002 and absf(roll_lean) < 0.002:
		return
	var fb: Basis = fighter.global_basis
	var to_sk: Basis = sk.global_transform.basis.orthonormalized().inverse() * fb
	var ax_x: Vector3 = (to_sk * Vector3.RIGHT).normalized()
	var ax_y: Vector3 = (to_sk * Vector3.UP).normalized()
	var ax_z: Vector3 = (to_sk * Vector3.BACK).normalized()
	# knee load first (hip sink) so the upper body is posed on top of the final hip
	if hinge > 0.002:
		var a := 12.0 * D * hinge
		_rot(sk, "lThighBend", ax_x, -a)
		_rot(sk, "rThighBend", ax_x, -a)
		_rot(sk, "lShin", ax_x, 2.0 * a)
		_rot(sk, "rShin", ax_x, 2.0 * a)
		var hip := sk.find_bone("hip")
		if hip >= 0:
			var drop := 0.9 * (1.0 - cos(a))
			var down_local: Vector3 = sk.global_transform.basis.orthonormalized().inverse() * Vector3.DOWN
			var parent := sk.get_bone_parent(hip)
			var pb := Basis.IDENTITY if parent < 0 else sk.get_bone_global_pose(parent).basis
			sk.set_bone_pose_position(hip, sk.get_bone_pose_position(hip) + pb.inverse() * (down_local * drop))
	# the order matters little (small angles); trunk bones go parent -> child
	var yaw := -22.0 * D * shell
	var hinge_a := 19.0 * D * hinge - 4.0 * D * shell
	var lat := -(lean * 26.0 * D + roll_lean * 17.0 * D)
	for e in TRUNK:
		var share: float = e[1]
		_rot(sk, e[0], ax_y, yaw * share)
		_rot(sk, e[0], ax_x, hinge_a * share)
		_rot(sk, e[0], ax_z, lat * share)
	for e in NECK:
		var share: float = e[1]
		# chin tuck (head pitches forward), neck leans with the torso a little more
		_rot(sk, e[0], ax_x, (9.0 * D * shell + 4.0 * D * hinge) * share)
		_rot(sk, e[0], ax_z, (-lean * 12.0 * D - roll_lean * 6.0 * D - shell * 6.0 * D) * share)
	if shell > 0.002:
		# lead (left) shoulder up to the chin
		_rot(sk, "lCollar", ax_z, 13.0 * D * shell)
		_rot(sk, "lShldrBend", ax_z, 6.0 * D * shell)
		_rot(sk, "rCollar", ax_z, -4.0 * D * shell)


## Rotates `bone` about its own origin by `angle` around the skeleton-space axis (children follow).
func _rot(sk: Skeleton3D, bone: String, axis: Vector3, angle: float) -> void:
	if absf(angle) < 0.00001:
		return
	var i := sk.find_bone(bone)
	if i < 0:
		return
	var g := sk.get_bone_global_pose(i)
	var parent := sk.get_bone_parent(i)
	var pb := Basis.IDENTITY if parent < 0 else sk.get_bone_global_pose(parent).basis
	var nb := Basis(axis, angle) * g.basis
	var local := pb.inverse() * nb
	sk.set_bone_pose_rotation(i, local.get_rotation_quaternion())
