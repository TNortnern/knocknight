extends SceneTree
## godot --headless --path . --fixed-fps 120 --script res://tools/probe_defence.gd -- block+shell block+slip duck+slip slip+back
## Holds each input combo on fighter 2 for 0.5 s, prints head offsets (fighter-local: x = left, y up, z towards foe).
var m: Match

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	m = load("res://scenes/match.tscn").instantiate()
	m.setup({"intro_delay": 0.0, "mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy", "rounds": 1, "round_seconds": 120.0})
	get_root().add_child(m)
	await process_frame
	var f: Array = m.get_fighters()
	f[0].global_position = Vector3(-0.45, 0, 0)
	f[1].global_position = Vector3(0.45, 0, 0)
	f[0].external_input = FighterInput.new()
	f[1].external_input = FighterInput.new()
	for i in 90:
		await physics_frame
	var me: Fighter = f[1]
	var inp: FighterInput = me.external_input
	for combo in OS.get_cmdline_user_args():
		var base := _head(me)
		inp.clear()
		for tok in combo.split("+"):
			match tok:
				"block": inp.block = true
				"shell": inp.shell = true
				"slip": inp.slip = 1
				"duck": inp.duck = true
				"back": inp.move = Vector2(1, 0)   # fighter 2 faces -x, so +x is away from the foe
		print("== ", combo, " base ", base)
		for i in 72:
			await physics_frame
			if i % 6 == 0:
				var h := _head(me) - base
				print("  t=%.2f st=%s kind=%s head d=(%.3f %.3f %.3f) stam=%.1f" % [i / 120.0, me.state_name, me.dm.kind, h.x, h.y, h.z, me.stats.stamina])
		inp.clear()
		for i in 120:
			await physics_frame
		print("  after: ", _head(me) - base, " ", me.state_name)
	quit(0)

func _head(me: Fighter) -> Vector3:
	var p := Vector3.ZERO
	for hu in me.rig.hurtboxes:
		if hu.zone == "head":
			p = hu.shape_node.global_position
	var d := p - me.global_position
	return Vector3(d.dot(me.global_basis.x), d.y, d.dot(me.global_basis.z))
