extends RefCounted
## Bakes the VISIBLE skinned body of a fighter (M3DMale or Meshy skin) vertex by vertex, grouped by gameplay-skeleton bone group.
## Call bake() from inside the driver skeleton's `skeleton_updated` signal (that is when the final pose is readable).
## Used by tools/measure_hits.gd and tests/test_hit_contact.gd.

static func group_of(bone: String) -> String:
	var side := bone.substr(0, 1)
	if bone == "head":
		return "head"
	if bone == "hip":
		return "pelvis"
	if bone.begins_with("chest"):
		return "chest"
	if bone.begins_with("abdomen"):
		return "abdomen"
	if bone.begins_with("neck"):
		return "neck"
	if bone == "lCollar" or bone == "rCollar":
		return "chest"
	if (side == "l" or side == "r") and bone.length() > 2 and bone.substr(1, 1) == bone.substr(1, 1).to_upper():
		var rest := bone.substr(1)
		if rest == "Hand" or rest.begins_with("Mid") or rest.begins_with("Index") or rest.begins_with("Ring") or rest.begins_with("Pinky") \
				or rest.begins_with("Thumb") or rest.begins_with("Carpal"):
			return "hand_" + side
		if rest.begins_with("Forearm"):
			return "fore_" + side
	return ""




## {groups: {name: Array[Vector3] world}, xf: {driver bone: world Transform3D}}
static func bake(f: Fighter) -> Dictionary:
	var groups := {}
	var xf := {}
	var drv: Skeleton3D = f.rig.skeleton
	for b in drv.get_bone_count():
		xf[drv.get_bone_name(b)] = drv.global_transform * drv.get_bone_global_pose(b)
	var skel: Skeleton3D = drv
	var root: Node = f.model_root
	var name_map := {}   # skeleton bone name -> driver bone name
	if f.meshy_skin != null:
		skel = f.meshy_skin.skeleton
		root = f.meshy_skin.root
		for pair in f.meshy_skin.MAP:
			name_map[pair[0]] = pair[1]
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null or m.skin == null or not m.visible:
			continue
		var sk2 := m.get_node_or_null(m.skeleton) as Skeleton3D
		if sk2 != skel:
			continue
		var skin := m.skin
		var tx := []
		for i in skin.get_bind_count():
			var bi := skin.get_bind_bone(i)
			var nm := skin.get_bind_name(i)
			if nm != "":
				bi = skel.find_bone(nm)
			tx.append(skel.global_transform * skel.get_bone_global_pose(bi) * skin.get_bind_pose(i) if bi >= 0 else Transform3D.IDENTITY)
		var grp_of_bind := []
		for i in skin.get_bind_count():
			var bi := skin.get_bind_bone(i)
			var nm := skin.get_bind_name(i)
			if nm != "":
				bi = skel.find_bone(nm)
			var bn := skel.get_bone_name(bi) if bi >= 0 else ""
			grp_of_bind.append(group_of(name_map.get(bn, bn) if f.meshy_skin != null else bn))
		for s in m.mesh.get_surface_count():
			var arr := m.mesh.surface_get_arrays(s)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var bones = arr[Mesh.ARRAY_BONES]
			var weights = arr[Mesh.ARRAY_WEIGHTS]
			if bones == null or weights == null or verts.is_empty():
				continue
			var per: int = bones.size() / verts.size()
			for v in verts.size():
				var best := -1.0
				var bi := 0
				var p := Vector3.ZERO
				for k in per:
					var w: float = weights[v * per + k]
					if w <= 0.0:
						continue
					var bidx: int = bones[v * per + k]
					p += (tx[bidx] as Transform3D) * verts[v] * w
					if w > best:
						best = w
						bi = bidx
				var g: String = grp_of_bind[bi]
				if g == "":
					continue
				if not groups.has(g):
					groups[g] = []
				groups[g].append(p)
	return {"groups": groups, "xf": xf}


## Torso vertices (spine chain, collars, the belly weighted to the pelvis) split at the chestLower joint into abdomen / chest.
static func add_torso(groups: Dictionary, xf: Dictionary) -> void:
	var torso: Array = groups["chest"] + groups["abdomen"] + groups.get("pelvis", [])
	var inv_abd: Transform3D = (xf["abdomenUpper"] as Transform3D).affine_inverse()
	var bot_y: float = (inv_abd * (xf["abdomenLower"] as Transform3D).origin).y
	var split_y: float = (inv_abd * (xf["chestLower"] as Transform3D).origin).y
	var top_y: float = (inv_abd * (xf["neckLower"] as Transform3D).origin).y
	var low := []
	var up := []
	for p in torso:
		var y: float = (inv_abd * p).y
		if y < bot_y:
			continue
		if y < split_y:
			low.append(p)
		elif y <= top_y:
			up.append(p)
	groups["t_abdomen"] = low
	groups["t_chest"] = up
