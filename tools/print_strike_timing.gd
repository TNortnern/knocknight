extends SceneTree
const CommitmentScript := preload("res://scripts/combat/commitment.gd")
## Prints contact time, active window, chain gate and total time of hand strikes (and their variants), plus how fast the
## clip plays (x authored speed) before contact, at contact and on the way back. Above ~1.6x mocap reads as fast-forward.
## <godot> --headless --path . --script res://tools/print_strike_timing.gd [base]
func _initialize() -> void:
	var only: String = OS.get_cmdline_user_args()[0] if OS.get_cmdline_user_args().size() > 0 else ""
	for base in StrikeDB.CORE_HAND + StrikeDB.CORE_BODY:
		if only != "" and base != only:
			continue
		for tag in [base] + StrikeDB.variant_tags(base):
			var s := StrikeDB.get_strike(tag)
			var tp: float = s["t_peak"]
			var a: float = s["action"]
			var lock := CommitmentScript.lock_time(s, a)
			var back := (StrikeDB.clip_time(s, lock) - float(s["clip_peak"])) / maxf(lock - tp, 0.001)
			print("%-22s contact %.3f  window %.3f-%.3f  chain %.3f  lock %.3f  action %.3f  clip %.2f/%.2f  speed out %.2fx (arrive %.2fx) back %.2fx" % [tag, tp, s["w0"], s["w1"], s["chain"], lock, a, s["clip_peak"], s["clip_len"], float(s["clip_peak"]) / tp, float(s["clip_peak"]) / tp * float(s["ease"]), back])
	quit()
