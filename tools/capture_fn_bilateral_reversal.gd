extends "res://tools/capture_fn_match.gd"
## Uses the fighter's existing auto-attached bilateral modifier; never attaches another.
## For scenario=circle only, substitute a pure lateral left/right/left reversal fixture.
func _fresh(pose_only: bool) -> bool:
	var ok: bool = await super._fresh(pose_only)
	if not ok:
		return false
	if defender.authored_slip != null:
		defender.authored_slip.record = true
	else:
		push_warning("Capture: authored modifier unavailable; recording procedural fallback")
	return true

func _apply_input_tick(seq_name: String, tick: int) -> void:
	super._apply_input_tick(seq_name, tick)
	if seq_name == "circle":
		var t := float(tick) / float(TICK_RATE)
		var x := 0.0
		if t >= 0.20 and t < 0.45:
			x = amplitude
		elif t >= 0.45 and t < 0.70:
			x = -amplitude
		elif t >= 0.70 and t < 0.95:
			x = amplitude
		defender.external_input.lean = Vector2(x, 0.0)
		defender.external_input.slip = 0

func _capture_sequence(seq_name: String, seq_dir: String, pose_only: bool) -> Dictionary:
	var doc: Dictionary = await super._capture_sequence(seq_name, seq_dir, pose_only)
	if seq_name == "circle" and not doc.is_empty():
		doc["schedule"] = {"fixture": "pure lateral reversal, circle scenario overridden by capture_bilateral.gd", "segments_seconds": [[0.20, 0.45, "left"], [0.45, 0.70, "right"], [0.70, 0.95, "left"]], "outside_segments": "neutral"}
	return doc

func _frame_record(index: int, time_s: float, tick: int, image_path: String) -> Dictionary:
	var row: Dictionary = super._frame_record(index, time_s, tick, image_path)
	if defender.authored_slip != null:
		row["authored_bilateral"] = defender.authored_slip.snapshot.duplicate(true)
	return row
