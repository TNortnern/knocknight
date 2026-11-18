extends RefCounted
## Cheap, repeatable sampling of the VISIBLE skinned body of a Meshy fighter, per body group, in world space.
## tools/mesh_bake.gd bakes every vertex (fine once, far too slow per physics frame); this keeps a decimated vertex set per group
## (head / neck / torso / gloves / forearms) with its skin weights cached, so a pose can be sampled in well under a millisecond per
## few hundred vertices. Used by tools/probe_hits.gd (ground-truth contact between visible meshes) and the hit sheet tools.
## Preload this script. Meshy fighters only (the classic M3DMale models are skinned on the gameplay skeleton itself).

const MeshBake := preload("res://tools/mesh_bake.gd")

## group -> max sample count (decimated by stride)
const CAPS := {"head": 300, "neck": 60, "chest": 220, "abdomen": 140, "pelvis": 60, "hand_l": 100, "hand_r": 100, "fore_l": 60, "fore_r": 60}

var fighter: Node3D
var _skel: Skeleton3D
var _meshes: Array = []   ## {mi, skin, binds: Array[int bone idx], groups: {group: {pos: PackedVector3Array, b: PackedInt32Array(4 per v), w: PackedFloat32Array(4 per v)}}}


static func make(f: Node3D) -> RefCounted:
	var s: RefCounted = (load("res://tools/skin_sampler.gd") as GDScript).new()
	s.set("fighter", f)
	s.call("_build")
	return s


func _build() -> void:
	var ms = fighter.meshy_skin
	assert(ms != null, "skin sampler needs a Meshy fighter")
	_skel = ms.skeleton
	var name_map := {}
	for pair in ms.MAP:
		name_map[pair[0]] = pair[1]
	# pass 1: count the vertices per group over all meshes, to pick one stride per group
	var raw: Array = []
	var totals := {}
	for mi in ms.root.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null or m.skin == null or not m.visible:
			continue
		var skin := m.skin
		var grp_of_bind := []
		var bone_of_bind := []
		for i in skin.get_bind_count():
			var bi := skin.get_bind_bone(i)
			var nm := skin.get_bind_name(i)
			if nm != "":
				bi = _skel.find_bone(nm)
			bone_of_bind.append(bi)
			var bn := _skel.get_bone_name(bi) if bi >= 0 else ""
			grp_of_bind.append(MeshBake.group_of(name_map.get(bn, bn)))
		for s in m.mesh.get_surface_count():
			var arr := m.mesh.surface_get_arrays(s)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var bones = arr[Mesh.ARRAY_BONES]
			var weights = arr[Mesh.ARRAY_WEIGHTS]
			if bones == null or weights == null or verts.is_empty():
				continue
			var per: int = bones.size() / verts.size()
			var dom := PackedStringArray()
			dom.resize(verts.size())
			for v in verts.size():
				var best := -1.0
				var bi2 := 0
				for k in per:
					var w: float = weights[v * per + k]
					if w > best:
						best = w
						bi2 = bones[v * per + k]
				var g: String = grp_of_bind[bi2]
				dom[v] = g
				if g != "":
					totals[g] = int(totals.get(g, 0)) + 1
			raw.append({"mi": m, "skin": skin, "bone_of_bind": bone_of_bind, "verts": verts, "bones": bones, "weights": weights, "per": per, "dom": dom})
	var stride := {}
	for g in totals:
		stride[g] = maxi(1, int(ceil(float(totals[g]) / float(CAPS.get(g, 200)))))
	var counters := {}
	for r in raw:
		var entry := {"mi": r["mi"], "skin": r["skin"], "bone_of_bind": r["bone_of_bind"], "groups": {}}
		var verts: PackedVector3Array = r["verts"]
		var per: int = r["per"]
		var bones = r["bones"]
		var weights = r["weights"]
		var dom: PackedStringArray = r["dom"]
		for v in verts.size():
			var g: String = dom[v]
			if g == "":
				continue
			var c: int = int(counters.get(g, 0))
			counters[g] = c + 1
			if c % int(stride[g]) != 0:
				continue
			if not entry["groups"].has(g):
				entry["groups"][g] = {"pos": PackedVector3Array(), "b": PackedInt32Array(), "w": PackedFloat32Array()}
			var gd: Dictionary = entry["groups"][g]
			var gp: PackedVector3Array = gd["pos"]
			var gb: PackedInt32Array = gd["b"]
			var gw: PackedFloat32Array = gd["w"]
			gp.append(verts[v])
			for k in 4:
				if k < per:
					gb.append(bones[v * per + k])
					gw.append(weights[v * per + k])
				else:
					gb.append(0)
					gw.append(0.0)
			gd["pos"] = gp
			gd["b"] = gb
			gd["w"] = gw
		_meshes.append(entry)


## World positions of the sampled vertices of each requested group, in the pose the Meshy skeleton holds right now.
## Returns {group: PackedVector3Array}.
func sample(groups: Array) -> Dictionary:
	var out := {}
	for g in groups:
		out[g] = PackedVector3Array()
	var sk_xf := _skel.global_transform
	for e in _meshes:
		var skin: Skin = e["skin"]
		var tx := []
		var bob: Array = e["bone_of_bind"]
		for i in skin.get_bind_count():
			var bi: int = bob[i]
			tx.append(sk_xf * _skel.get_bone_global_pose(bi) * skin.get_bind_pose(i) if bi >= 0 else Transform3D.IDENTITY)
		for g in groups:
			if not e["groups"].has(g):
				continue
			var gd: Dictionary = e["groups"][g]
			var pos: PackedVector3Array = gd["pos"]
			var bb: PackedInt32Array = gd["b"]
			var ww: PackedFloat32Array = gd["w"]
			var dst := PackedVector3Array()
			for v in pos.size():
				var p := Vector3.ZERO
				var lp := pos[v]
				for k in 4:
					var w := ww[v * 4 + k]
					if w > 0.0:
						p += (tx[bb[v * 4 + k]] as Transform3D) * lp * w
				dst.append(p)
			var acc: PackedVector3Array = out[g]
			acc.append_array(dst)
			out[g] = acc
	return out


static func centroid(pts: PackedVector3Array) -> Vector3:
	var c := Vector3.ZERO
	for p in pts:
		c += p
	return c / maxf(pts.size(), 1)


## Smallest vertex-to-vertex distance between two sampled point clouds (m). 9.0 when either is empty.
static func min_dist(a: PackedVector3Array, b: PackedVector3Array) -> float:
	var best := 9.0e9
	for p in a:
		for q in b:
			var d := p.distance_squared_to(q)
			if d < best:
				best = d
	return sqrt(best) if best < 8.9e9 else 9.0
