extends SceneTree
## godot --headless --path . --script res://tools/measure_counters.gd  -> writes data/counter_measure.json
## Strike window of the authored DEF_counter_* clips (rear hook, right hand), measured like tools/measure_strikes.gd.
func _initialize():
	var p: PackedScene = load("res://assets/fighters/viper.glb")
	var r = p.instantiate()
	get_root().add_child(r)
	await process_frame
	var sk: Skeleton3D = r.find_child("Skeleton3D", true, false)
	var ap: AnimationPlayer = r.find_child("AnimationPlayer", true, false)
	var out := {}
	for kind in ["slip", "sway"]:
		for side in ["left", "right"]:
			for dist in ["near", "mid", "far"]:
				var clip := "DEF_counter_%s_%s_%s" % [kind, side, dist]
				if not ap.has_animation(clip):
					print("missing ", clip)
					continue
				var a := ap.get_animation(clip)
				var tipb := sk.find_bone("rMid1")
				var pelb := sk.find_bone("pelvis")
				var n := int(a.length * 120.0)
				var ext := PackedFloat32Array()
				ap.play(clip)
				for i in n + 1:
					ap.seek(float(i) / 120.0, true)
					var t := sk.get_bone_global_pose(tipb).origin - sk.get_bone_global_pose(pelb).origin
					ext.append(Vector2(t.x, t.z).length())
				var mx := -INF
				var mn := INF
				var pk := 0
				for i in ext.size():
					if ext[i] > mx:
						mx = ext[i]
						pk = i
					mn = min(mn, ext[i])
				var thr := mn + 0.65 * (mx - mn)
				var i0 := pk
				var i1 := pk
				while i0 > 0 and ext[i0 - 1] >= thr:
					i0 -= 1
				while i1 < ext.size() - 1 and ext[i1 + 1] >= thr:
					i1 += 1
				out[clip] = {"len": a.length, "peak": pk / 120.0, "w0": i0 / 120.0, "w1": i1 / 120.0, "ext_max": snappedf(mx, 0.001)}
				print("%-30s len=%.2f peak=%.2f win %.2f-%.2f ext=%.2f" % [clip, a.length, pk / 120.0, i0 / 120.0, i1 / 120.0, mx])
	var f := FileAccess.open("res://data/counter_measure.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(out, " "))
	f.close()
	quit()
