extends "res://tools/capture_fn_match.gd"
## Standalone capture entrypoint: copy into project tools only when the project is free.
## Measurements are appended to selected frame records, after frame_post_draw.

const SAMPLE_FRAMES := [0, 6, 15, 20, 24]
const FOOT_WEIGHT_MIN := 0.5
const END_FRACTION := 0.25
var _foot_setup: Dictionary = {}

func _fresh(pose_only: bool) -> bool:
	_foot_setup = {}
	return await super._fresh(pose_only)

func _frame_record(index: int, time_s: float, tick: int, image_path: String) -> Dictionary:
	var row: Dictionary = super._frame_record(index, time_s, tick, image_path)
	if index in SAMPLE_FRAMES:
		if _foot_setup.is_empty():
			_foot_setup = _prepare_foot_measurement()
		row["meshy_foot_measurement"] = _measure_feet(index, tick)
	return row

func _prepare_foot_measurement() -> Dictionary:
	if defender == null or defender.get("meshy_skin") == null:
		return {"error": "defender has no MeshySkin"}
	var ms: Node = defender.get("meshy_skin")
	var sk: Skeleton3D = ms.get("skeleton") as Skeleton3D
	var skin_root: Node = ms.get("root") as Node
	if sk == null or skin_root == null:
		return {"error": "Meshy skeleton or model missing"}
	var candidates: Array = []
	for node in skin_root.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = node as MeshInstance3D
		if mi.mesh != null and mi.get_skin_reference() != null:
			candidates.append(mi)
	if candidates.size() != 1:
		return {"error": "expected one skinned Meshy mesh, found %d" % candidates.size()}
	var mesh_instance: MeshInstance3D = candidates[0]
	var mesh: Mesh = mesh_instance.mesh
	var skin_ref: SkinReference = mesh_instance.get_skin_reference()
	var skin: Skin = skin_ref.get_skin()
	if skin == null:
		return {"error": "missing registered skin"}
	# The bake skips unsupported surfaces; reject them to preserve surface-index correspondence.
	for surface in mesh.get_surface_count():
		var fmt: int = mesh.surface_get_format(surface)
		if mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES or (fmt & Mesh.ARRAY_FORMAT_BONES) == 0 or (fmt & Mesh.ARRAY_FORMAT_WEIGHTS) == 0:
			return {"error": "surface %d is not a skinned triangle surface" % surface}
	var result: Dictionary = {"mesh": mesh_instance, "skeleton": sk, "skin": skin, "feet": {}}
	var mesh_to_skeleton: Transform3D = sk.global_transform.affine_inverse() * mesh_instance.global_transform
	for side in ["Left", "Right"]:
		var foot_idx: int = sk.find_bone(side + "Foot")
		var toe_idx: int = sk.find_bone(side + "ToeBase")
		if foot_idx < 0 or toe_idx < 0:
			return {"error": "missing " + side + "Foot or ToeBase"}
		var bind_ids: Array = []
		for b in skin.get_bind_count():
			var name: String = String(skin.get_bind_name(b))
			var bone: int = skin.get_bind_bone(b)
			if name == side + "Foot" or name == side + "ToeBase" or bone == foot_idx or bone == toe_idx:
				bind_ids.append(b)
		if bind_ids.is_empty():
			return {"error": "no skin binds for " + side + " foot"}
		var ankle: Vector3 = sk.get_bone_global_rest(foot_idx).origin
		var toe: Vector3 = sk.get_bone_global_rest(toe_idx).origin
		var axis: Vector3 = (toe - ankle).normalized()
		if axis.length_squared() < 0.9:
			return {"error": "zero-length rest foot axis for " + side}
		var selected: Array = []
		var low: float = INF
		var high: float = -INF
		for surface in mesh.get_surface_count():
			var arrays: Array = mesh.surface_get_arrays(surface)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var bones = arrays[Mesh.ARRAY_BONES]
			var weights = arrays[Mesh.ARRAY_WEIGHTS]
			var influences: int = 8 if (mesh.surface_get_format(surface) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS) != 0 else 4
			if bones.size() != verts.size() * influences or weights.size() != verts.size() * influences:
				return {"error": "unexpected bone/weight array lengths at surface %d" % surface}
			for vi in verts.size():
				var foot_weight: float = 0.0
				for j in influences:
					var at: int = vi * influences + j
					if int(bones[at]) in bind_ids:
						foot_weight += float(weights[at])
				if foot_weight > FOOT_WEIGHT_MIN:
					var along: float = ((mesh_to_skeleton * verts[vi]) - ankle).dot(axis)
					selected.append({"surface": surface, "vertex": vi, "along": along})
					low = minf(low, along)
					high = maxf(high, along)
		if selected.size() < 20 or high - low < 0.00001:
			return {"error": "not enough foot-weighted vertices for " + side}
		var heel: Array = []
		var toe_end: Array = []
		for v in selected:
			if float(v["along"]) <= low + END_FRACTION * (high - low):
				heel.append(v)
			if float(v["along"]) >= high - END_FRACTION * (high - low):
				toe_end.append(v)
		result["feet"][side] = {"all": selected, "heel": heel, "toe": toe_end, "axis_min": low, "axis_max": high}
	return result

func _measure_feet(index: int, tick: int) -> Dictionary:
	if _foot_setup.has("error"):
		return {"status": "error", "message": _foot_setup["error"]}
	# Canvas is the base slab, not the decorative logo and stripes above it.
	var canvases: Array = root.find_children("Canvas", "MeshInstance3D", true, false)
	if canvases.size() != 1 or not (canvases[0].mesh is BoxMesh):
		return {"status": "error", "message": "expected exactly one BoxMesh Canvas"}
	var canvas: MeshInstance3D = canvases[0]
	var box: BoxMesh = canvas.mesh as BoxMesh
	var plane_point: Vector3 = canvas.global_transform * Vector3(0.0, box.size.y * 0.5, 0.0)
	var plane_normal: Vector3 = (canvas.global_transform.basis.inverse().transposed() * Vector3.UP).normalized()
	if plane_normal.dot(Vector3.UP) < 0.0:
		plane_normal = -plane_normal
	var mi: MeshInstance3D = _foot_setup["mesh"]
	if not mi.has_method("bake_mesh_from_current_skeleton_pose"):
		return {"status": "error", "message": "Godot skeleton-pose bake API unavailable"}
	var baked: ArrayMesh = mi.bake_mesh_from_current_skeleton_pose()
	if baked == null or baked.get_surface_count() != mi.mesh.get_surface_count():
		return {"status": "error", "message": "skeleton bake failed or surface count changed"}
	var baked_arrays: Array = []
	for surface in baked.get_surface_count():
		var a: Array = baked.surface_get_arrays(surface)
		var source: Array = mi.mesh.surface_get_arrays(surface)
		if a[Mesh.ARRAY_VERTEX].size() != source[Mesh.ARRAY_VERTEX].size():
			return {"status": "error", "message": "baked/source vertex counts differ on surface %d" % surface}
		baked_arrays.append(a[Mesh.ARRAY_VERTEX])
	var out: Dictionary = {"status": "ok", "frame_index": index, "input_tick": tick,
		"physics_frame_at_read": Engine.get_physics_frames(), "method": "renderer skeleton bake after frame_post_draw; blend shapes ignored",
		"mesh_path": String(mi.get_path()), "canvas_path": String(canvas.get_path()),
		"plane_point_world_m": _foot_vec(plane_point), "plane_normal_world": _foot_vec(plane_normal),
		"weight_threshold": FOOT_WEIGHT_MIN, "end_fraction": END_FRACTION, "feet": {}}
	for side in ["Left", "Right"]:
		var groups: Dictionary = _foot_setup["feet"][side]
		out["feet"][side] = {}
		for group in ["all", "heel", "toe"]:
			out["feet"][side][group] = _summarize_region(groups[group], baked_arrays, mi.global_transform, plane_point, plane_normal)
		out["feet"][side]["rest_axis_range_skeleton_units"] = [groups["axis_min"], groups["axis_max"]]
	return out

func _summarize_region(vertices: Array, arrays: Array, world: Transform3D, plane_point: Vector3, plane_normal: Vector3) -> Dictionary:
	var heights: Array = []
	var lowest: Dictionary = {}
	var min_height: float = INF
	for v in vertices:
		var pos: Vector3 = world * arrays[int(v["surface"])][int(v["vertex"])]
		var h: float = (pos - plane_point).dot(plane_normal)
		heights.append(h)
		if h < min_height:
			min_height = h
			lowest = {"signed_height_m": h, "world_m": _foot_vec(pos), "surface": v["surface"], "vertex": v["vertex"]}
	if heights.is_empty():
		return {"status": "empty", "count": 0}
	heights.sort()
	var p05_index: int = int(floor(float(heights.size() - 1) * 0.05))
	return {"status": "ok", "count": heights.size(), "minimum": lowest, "p05_signed_height_m": heights[p05_index]}

static func _foot_vec(v: Vector3) -> Array:
	return [v.x, v.y, v.z]

func _aim_static_camera() -> void:
	super._aim_static_camera()
	capture_cam.fov = 50.0
