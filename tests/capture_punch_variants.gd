extends SceneTree
## Windowed footage of punch variants: real main.tscn, scripted P1 throws one variant at a standing P2, side camera
## (both fighters in frame), frames every 8 physics ticks (1/15 s of sim time) of the whole action + recovery.
##   godot --path . --script res://tests/capture_punch_variants.gd -- [name=LJab~flick@1.0 ...]
## An entry is `tag[@gap]`, optional suffix `:auto` throws "tag@auto" (human-style choice) and `:x2` throws it twice.
## Writes _build/shots/punch_<tag>_NN.png and a contact sheet punch_<tag>_sheet.png per entry.

const DEFAULT := ["LJab", "LJab~flick", "LJab~pull", "LJab~lunge@1.25", "RJab", "RJab~flick", "RJab~lunge@1.25",
	"LHook", "LHook~tight", "LHook~wide@1.1", "RHook", "RHook~tight", "RHook~wide@1.1", "LUppercut", "LUppercut~rise",
	"RUppercut", "RUppercut~rise", "LBodyHook", "LBodyHook~power", "RBodyJab", "RBodyJab~power",
	"LJab~lunge@1.9", "RHook~wide@1.9", "LHook~wide@1.9", "RUppercut~rise@1.9", "LJab:x2", "LJab:x3"]
const STEP_TICKS := 67   # at time_scale 0.12 a physics tick is 0.001 s of sim time: 67 ticks = 1/15 s
const FRAMES := 14
const CELL := Vector2i(500, 400)
const COLS := 5


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_build/shots"))
	var entries: Array = DEFAULT
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		entries = args
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.start_match({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy",
		"p1_model": "viper", "p2_model": "anvil", "rules": "boxing", "rounds": 1,
		"round_seconds": 600.0, "arena": "ring", "intro_delay": 0.0})
	var f: Array = main.current_match.get_fighters()
	f[0].external_input = FighterInput.new()
	f[1].external_input = FighterInput.new()
	for c in main.find_children("*", "CanvasLayer", true, false):
		(c as CanvasLayer).visible = false
	var cam := Camera3D.new()
	cam.fov = 30
	root.add_child(cam)
	for entry in entries:
		await _shoot(f, cam, entry)
	Engine.time_scale = 1.0
	quit(0)


func _shoot(f: Array, cam: Camera3D, entry: String) -> void:
	var tag := entry
	var gap := 0.92
	var repeat := 1
	var auto := false
	if tag.contains(":"):
		var parts := tag.split(":")
		tag = parts[0]
		for p in parts.slice(1):
			if p == "auto":
				auto = true
			elif p.begins_with("x"):
				repeat = int(p.substr(1))
				auto = true
	if tag.contains("@"):
		var parts2 := tag.split("@")
		tag = parts2[0]
		gap = float(parts2[1])
	var name := entry.replace("~", "_").replace("@", "_").replace(":", "_")
	f[0].reset_for_round(Vector3(-gap * 0.5, 0, 0), true)
	f[1].reset_for_round(Vector3(gap * 0.5, 0, 0), true)
	f[0].stats.infinite_stamina = true
	f[1].stats.infinite_stamina = true
	f[0].external_input.strikes.clear()
	for i in 600:
		await physics_frame
		if i > 90 and not f[0].frozen and not f[0].input_locked and f[0].can_act():
			break
	var sheet := Image.create(CELL.x * COLS, CELL.y * ((FRAMES + COLS - 1) / COLS), false, Image.FORMAT_RGBA8)
	Engine.time_scale = 0.12
	var throw_tag := tag + ("@auto" if auto else "")
	f[0].external_input.strikes.append(throw_tag)
	await physics_frame
	f[0].external_input.strikes.clear()
	print("  ", entry, " -> atk ", f[0].atk.get("tag", "NONE"), " clip ", (f[0].atk.get("s", {}) as Dictionary).get("clip", ""))
	var thrown := 1
	for n in FRAMES:
		for i in STEP_TICKS:
			await physics_frame
			if thrown < repeat and f[0].atk.has("t") and f[0].atk["t"] >= 0.12 * thrown:
				f[0].external_input.strikes.append(throw_tag)
				thrown += 1
			else:
				f[0].external_input.strikes.clear()
		var mid: Vector3 = (f[0].global_position + f[1].global_position) * 0.5
		cam.global_position = Vector3(mid.x, 1.15, 3.5)
		cam.look_at(Vector3(mid.x, 1.02, 0.0))
		cam.make_current()
		await process_frame
		await RenderingServer.frame_post_draw
		var img := root.get_viewport().get_texture().get_image()
		img.convert(Image.FORMAT_RGBA8)
		var w := img.get_width()
		var h := img.get_height()
		var cw := int(h * float(CELL.x) / float(CELL.y))
		var crop := img.get_region(Rect2i((w - cw) / 2, 0, cw, h))
		crop.resize(CELL.x, CELL.y)
		crop.save_png("res://_build/shots/punch_%s_%02d.png" % [name, n])
		sheet.blit_rect(crop, Rect2i(Vector2i.ZERO, CELL), Vector2i((n % COLS) * CELL.x, (n / COLS) * CELL.y))
	Engine.time_scale = 1.0
	sheet.save_png("res://_build/shots/punch_%s_sheet.png" % name)
	print("shot ", entry, " -> punch_%s_sheet.png" % name)
