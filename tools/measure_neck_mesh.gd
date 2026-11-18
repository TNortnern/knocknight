extends SceneTree
## Static rest-pose measurement of the Meshy fighter meshes: neck width / depth vs head and shoulders, in metres (skin scale applied).
## godot --headless --path . --script res://tools/measure_neck_mesh.gd
func _initialize() -> void:
	for skin in ["viper_alt", "anvil", "oak", "boxer1", "boxer2"]:
		var root: Node = (load("res://assets/fighters/meshy/%s.glb" % skin) as PackedScene).instantiate()
		get_root().add_child(root)
		var sk: Skeleton3D = root.find_child("Skeleton3D", true, false)
		var head_y := sk.get_bone_global_rest(sk.find_bone("Head")).origin.y
		var neck_y := sk.get_bone_global_rest(sk.find_bone("neck")).origin.y
		var sh_y := sk.get_bone_global_rest(sk.find_bone("LeftArm")).origin.y
		var sh_x := absf(sk.get_bone_global_rest(sk.find_bone("LeftArm")).origin.x)
		var scale := 1.0
		var pts: Array = []
		for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
			var skin_res: Skin = mi.skin
			if skin_res == null or mi.mesh == null:
				continue
			var map := PackedInt32Array()
			for i in skin_res.get_bind_count():
				map.append(sk.find_bone(skin_res.get_bind_name(i)) if skin_res.get_bind_name(i) != "" else skin_res.get_bind_bone(i))
			for s in mi.mesh.get_surface_count():
				var arr := mi.mesh.surface_get_arrays(s)
				var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				var bs = arr[Mesh.ARRAY_BONES]
				var ws = arr[Mesh.ARRAY_WEIGHTS]
				var per := int(bs.size() / vs.size())
				for k in vs.size():
					var p := Vector3.ZERO
					var wsum := 0.0
					for j in per:
						var wj: float = ws[k * per + j]
						if wj > 0.0:
							var bi := int(bs[k * per + j])
							p += wj * (sk.get_bone_global_rest(map[bi]) * skin_res.get_bind_pose(bi) * vs[k])
							wsum += wj
					if wsum > 0.0:
						pts.append(p / wsum)
		var out := {}
		for nm in [["neck_lo", neck_y + 0.15 * (head_y - neck_y)], ["neck_mid", neck_y + 0.5 * (head_y - neck_y)], ["neck_hi", neck_y + 0.85 * (head_y - neck_y)], ["head", head_y + 0.55 * (head_y - neck_y)]]:
			var y: float = nm[1]
			var minx := 9e9; var maxx := -9e9; var minz := 9e9; var maxz := -9e9
			var n := 0
			for p in pts:
				if absf(p.y - y) < 0.01 * (head_y / 1.5) and absf(p.x) < sh_x * 0.9:
					minx = minf(minx, p.x); maxx = maxf(maxx, p.x); minz = minf(minz, p.z); maxz = maxf(maxz, p.z); n += 1
			out[nm[0]] = [maxx - minx, maxz - minz, n]
		# scale: the game scales the model so the Head joint sits at the M3DMale head height (~1.5 m); report ratios, and cm at that scale
		print("%s: head_y %.1f neck_y %.1f (neck bone length %.1f = %.0f%% of head y)  shoulder half-width %.1f" % [skin, head_y, neck_y, head_y - neck_y, 100.0 * (head_y - neck_y) / head_y, sh_x])
		for k in out:
			print("   %-9s width %.1f  depth %.1f  (verts %d)" % [k, out[k][0], out[k][1], out[k][2]])
		root.queue_free()
	quit()
