extends RefCounted
## Short global time dips for knockdown / KO impacts. Always restores Engine.time_scale (real-time timer that keeps
## running while the tree is paused), and `restore()` is also called when a match node leaves the tree.

static var _token := 0


static func slowmo(tree: SceneTree, scale: float, real_seconds: float) -> void:
	if tree == null:
		return
	_token += 1
	var mine := _token
	Engine.time_scale = scale
	# process_always = true, process_in_physics = false, ignore_time_scale = true
	await tree.create_timer(real_seconds, true, false, true).timeout
	if mine == _token:
		Engine.time_scale = 1.0


static func restore() -> void:
	_token += 1
	Engine.time_scale = 1.0
