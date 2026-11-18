extends SceneTree
## Windowed: each Meshy fighter (P1, left) in guard, throwing a hook and knocked out -> _build/shots/mr_<id>_<shot>.png
## <godot> --path . --script res://tools/capture_meshy_roster.gd -- [ids=meshy_viper,meshy_oak] [debug=1]
## then: python -I tools/make_meshy_sheet.py
const RosterScript := preload("res://scripts/fighter/roster.gd")
var m: Match
var debug := false


func shot(name: String) -> void:
	await process_frame
	await process_frame
	get_root().get_texture().get_image().save_png("res://_build/shots/mr_%s.png" % name)


func steps(n: int) -> void:
	for i in n:
		await physics_frame


func make(p1: String, p2: String, gap: float) -> Array:
	if m != null:
		get_root().remove_child(m)
		m.queue_free()
		await process_frame
	m = load("res://scenes/match.tscn").instantiate()
	m.debug_boxes = debug
	m.setup({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy", "p1_model": p1, "p2_model": p2, "rules": "boxing",
		"rounds": 1, "round_seconds": 120.0, "intro_delay": 0.0})
	get_root().add_child(m)
	await process_frame
	var f: Array = m.get_fighters()
	f[0].global_position = Vector3(-gap * 0.5, 0, 0)
	f[1].global_position = Vector3(gap * 0.5, 0, 0)
	f[0].external_input = FighterInput.new()
	f[1].external_input = FighterInput.new()
	f[0].stats.infinite_stamina = true
	f[1].stats.infinite_stamina = true
	await steps(100)
	return f


func cam(at: Vector3, from_z := 2.7) -> void:
	var c: Camera3D = m.get_node("PlaceholderArena/Camera3D")
	c.fov = 34.0
	c.look_at_from_position(Vector3(at.x, 1.15, from_z), Vector3(at.x, 0.95, 0))


func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 720))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_build/shots"))
	var ids: Array = RosterScript.ORDER.filter(func(i): return RosterScript.skin_path(i) != "")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("ids="):
			ids = a.substr(4).split(",")
		if a == "debug=1":
			debug = true
	for k in ids.size():
		var fid: String = ids[k]
		var foe: String = ids[(k + 1) % ids.size()]
		var f := await make(fid, foe, 1.1)
		cam(Vector3(-0.1, 0, 0))
		await shot(fid + "_guard")
		f[0].external_input.strikes.append("RHook")
		await steps(1)
		f[0].external_input.strikes.clear()
		await steps(22)
		await shot(fid + "_hook")
		f = await make(fid, foe, 1.2)
		f[0]._do_ko("KO", "F", "head")
		await steps(60)
		cam(Vector3(-0.3, 0, 0), 3.4)
		await shot(fid + "_ko1")
		await steps(240)
		await shot(fid + "_ko2")
	quit()
