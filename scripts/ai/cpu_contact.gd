extends RefCounted
## CPU behaviour in body contact (one instance per brain, CpuBrain.contact). Small probabilistic behaviours, they do not
## change the overall pacing:
##   pressure fighters (cpu_style "pressure": Anvil / Oak) lean on the foe and walk him to the ropes, then work short punches
##   out-boxers ("out-boxer": Viper) shove off when leaned on or pinned (footwork already pivots out of a corner)
##   everybody shoves now and then when a clinch goes on, and uses short punches (uppercuts, body hooks) in close
## Chest to chest (inside fighting) the brain picks a "work" for 0.7-1.6 s at a time by style: fight for head position
## (bc.head_push), frame with the lead forearm (bc.frame_hold), lean and push, or work the body / uppercuts; shoving off
## stays a separate roll below. Pressure fighters push + head + body, out-boxers frame and get out, the rest mix.
## The rules are in scripts/fighter/body_contact.gd, the input is FighterInput.shove / FighterInput.move.

const BodyContactScript := preload("res://scripts/fighter/body_contact.gd")

var lean_t := 0.0      ## s left of the current lean-on window
var lean_cd := 0.5
var shove_cd := 0.0
var el := 0.0          ## s in contact range
var shoves := 0
var leans := 0
var work := ""         ## "head" | "frame" | "push" | "body" | "" while chest to chest
var work_t := 0.0
var works := {}        ## diagnostics: how often each work was picked


func tick(b, dt: float, inp: FighterInput, gap: float, to_foe: Vector3) -> void:
	var f = b.f
	var foe = f.foe
	shove_cd = maxf(shove_cd - dt, 0.0)
	lean_cd = maxf(lean_cd - dt, 0.0)
	lean_t = maxf(lean_t - dt, 0.0)
	work_t = maxf(work_t - dt, 0.0)
	if foe == null or gap > 1.0 or not f.bc.in_contact:
		work = ""
		f.bc.head_push = 0.0
	if foe == null or f.state != Fighter.State.IDLE or gap > 1.0:
		el = 0.0
		lean_t = 0.0
		return
	el += dt
	_inside_work(b, dt, inp)
	var style: String = String(b.style.get("name", ""))
	var pressure: bool = style == "pressure"
	var outboxer: bool = style == "out-boxer"
	var me: Vector3 = f.global_position
	var fp: Vector3 = foe.global_position
	var foe_on_ropes: bool = maxf(absf(fp.x), absf(fp.z)) > 2.3
	var pinned: bool = f.bc.pinned or (maxf(absf(me.x), absf(me.z)) > 2.4 and foe.bc.drive > 0.3)
	# ---- shove off: out-boxers when leaned on / pinned, others when a clinch drags on
	if el > 0.3 and shove_cd <= 0.0 and f.bc.can_shove() and f.stats.stamina_ratio() > 0.15:
		var rate := 0.12
		if outboxer:
			rate = 0.7 if foe.bc.drive > 0.3 else 0.35
			if pinned:
				rate = 1.8
		elif pressure:
			rate = 0.8 if pinned else 0.08
		elif pinned or foe.bc.drive > 0.5:
			rate = 0.9
		if f.bc.contact_t > 1.2:
			rate += 0.8   # a long clinch: break it
		if b.rng.randf() < rate * dt:
			inp.shove = true
			shove_cd = 1.6
			shoves += 1
			lean_t = 0.0
			return
	# ---- lean on the foe (walk him back); pressure fighters mostly, everyone a little
	if lean_t <= 0.0 and lean_cd <= 0.0 and gap < 0.9 and f.stats.stamina_ratio() > 0.4 and not pinned:
		lean_cd = b.rng.randf_range(1.0, 2.4)
		var p := 0.5 if pressure else (0.03 if outboxer else 0.12)
		if foe_on_ropes:
			p += 0.25 if pressure else 0.1
		if b.rng.randf() < p:
			lean_t = b.rng.randf_range(0.9, 1.8)
			leans += 1
	if lean_t > 0.0 and inp.move.length() < 0.5:
		inp.move = Vector2(to_foe.x, -to_foe.z) * 0.9


func _inside_work(b, dt: float, inp: FighterInput) -> void:
	var f = b.f
	if not f.bc.in_contact:
		return
	var style: String = String(b.style.get("name", ""))
	if work_t <= 0.0:
		work_t = b.rng.randf_range(0.7, 1.6)
		var w := {"head": 0.3, "frame": 0.25, "push": 0.2, "body": 0.25}
		if style == "pressure":
			w = {"head": 0.30, "frame": 0.0, "push": 0.35, "body": 0.35}
		elif style == "out-boxer":
			w = {"head": 0.15, "frame": 0.55, "push": 0.0, "body": 0.30}
		if f.stats.stamina_ratio() < 0.35:
			w["frame"] = float(w["frame"]) + 0.4   # tired: tie up and hold the space
		if f.bc.pinned:
			w["frame"] = float(w["frame"]) + 0.3
		var tot := 0.0
		for k in w:
			tot += float(w[k])
		var r: float = b.rng.randf() * tot
		work = "head"
		for k in w:
			r -= float(w[k])
			if r <= 0.0:
				work = k
				break
		works[work] = int(works.get(work, 0)) + 1
		if work == "push":
			lean_t = maxf(lean_t, work_t)
	match work:
		"head":
			f.bc.head_push = 1.0
		"frame":
			f.bc.frame_hold = maxf(f.bc.frame_hold, 0.25)
			lean_t = 0.0
			f.bc.head_push = 0.0
		"push":
			f.bc.head_push = 0.5
		_:
			f.bc.head_push = 0.3 if style == "pressure" else 0.0


## A short punch for close range (uppercuts / body hooks / a tight hook), or "" to let the normal choice run.
func short_tag(b, gap: float, foe_hurt: bool) -> String:
	if gap >= 0.80 or foe_hurt:
		return ""
	var style: String = String(b.style.get("name", ""))
	var p := 0.40 if style == "pressure" else (0.15 if style == "out-boxer" else 0.25)
	if work == "body":
		p = minf(p * 2.0 + 0.1, 0.85)   # working the body / uppercuts inside
	elif work == "frame":
		p *= 0.4                         # framing: not punching
	if b.rng.randf() >= p:
		return ""
	var f = b.f
	var foe_on_ropes: bool = maxf(absf(f.foe.global_position.x), absf(f.foe.global_position.z)) > 2.3
	var m: float = b.rng.randf()
	if foe_on_ropes and m < 0.3:
		return "LBodyHook" if b.rng.randf() < 0.5 else "RBodyHook"
	if m < 0.22:
		return "LUppercut"
	if m < 0.44:
		return "RUppercut"
	if m < 0.62:
		return "LBodyHook"
	if m < 0.80:
		return "RBodyHook"
	return "LHook"
