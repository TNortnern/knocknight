class_name FistPose
extends SkeletonModifier3D
## Closes both hands into fists after the animation pass (finger bones are not animated in the clips).
## Fingers extend along +X (left hand) / -X (right hand) in the rest pose; they curl about Z towards the palm.

@export var curl_deg := Vector3(78.0, 92.0, 62.0)
@export var thumb_deg := Vector3(10.0, 38.0, 30.0)

var _fingers: Array = []   # [bone_idx, Quaternion]
var _built := false


func _build() -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	_built = true
	for side in ["l", "r"]:
		var dirn := -1.0 if side == "l" else 1.0
		for f in ["Index", "Mid", "Ring", "Pinky"]:
			for j in 3:
				var idx := sk.find_bone("%s%s%d" % [side, f, j + 1])
				if idx < 0:
					continue
				var a := deg_to_rad(curl_deg[j]) * dirn
				_fingers.append([idx, Quaternion(Vector3.BACK, a)])
		# thumb: fold across the palm (about Z) with a little roll about the finger axis
		for j in 3:
			var idx := sk.find_bone("%sThumb%d" % [side, j + 1])
			if idx < 0:
				continue
			var q := Quaternion(Vector3.BACK, deg_to_rad(thumb_deg[j]) * dirn * 0.6) \
				* Quaternion(Vector3.UP, deg_to_rad(thumb_deg[j]) * dirn * -0.8)
			_fingers.append([idx, q])


func _process_modification_with_delta(_delta: float) -> void:
	if not _built:
		_build()
	var sk := get_skeleton()
	if sk == null:
		return
	for e in _fingers:
		sk.set_bone_pose_rotation(e[0], sk.get_bone_rest(e[0]).basis.get_rotation_quaternion() * (e[1] as Quaternion))
