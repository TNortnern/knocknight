class_name FighterAnimator
extends RefCounted
## Builds and drives the AnimationTree of one fighter.
##
## BlendTree layout:
##   Base (StateMachine: Move / Rocked, each a BlendSpace2D) -> BaseScale (TimeScale)
##   SlotA / SlotB (AnimationNodeAnimation -> TimeSeek -> TimeScale) -> Mix (Blend2: crossfade A<->B)
##   Act   (Blend2: Base vs Mix)       - one-shot strikes / reactions / defence / KO, weight fades 0..1
##   Guard (Blend2 filtered to the upper body: Act vs GuardAnim) - held guard layer
## Animations come from the glb's own AnimationPlayer library (loop modes patched from data/clips.json).

const CLIP_ALIASES := {"KB_Block_Loop": "KB_Block"}
const LOCO_SPACE := {
	"stand": [
		["KB_Idle_1", Vector2(0, 0)], ["KB_WalkFwd2", Vector2(0, 1)], ["KB_WalkBwd", Vector2(0, -1)],
		["KB_Sidestep_L", Vector2(1, 0)], ["KB_WalkLeft45", Vector2(0.7, 0.7)], ["KB_WalkLeft135", Vector2(0.7, -0.7)],
		["KB_WalkRight45", Vector2(-0.7, 0.7)], ["KB_WalkRight135", Vector2(-0.7, -0.7)],
	],
}
const FORCE_LOOP := ["KB_Idle_1", "KB_WalkFwd2", "KB_WalkBwd", "KB_Sidestep_L", "KB_WalkLeft45", "KB_WalkLeft135",
	"KB_WalkRight45", "KB_WalkRight135"]

## Lean layer (slips / sway / bob): authored hold poses of the defence pack blended by the analog lean vector
## (x = fighter's left, y = forward(+) / back(-)). [clip template, point]; "%s" = "" or "_block" (guard up).
const LEAN_POINTS := [
	["DEF_slip_left%s_hold", Vector2(1, 0)], ["DEF_slip_right%s_hold", Vector2(-1, 0)],
	["DEF_sway_left%s_hold", Vector2(0.5, -1)], ["DEF_sway_right%s_hold", Vector2(-0.5, -1)],
	["DEF_duck%s_hold", Vector2(0, 1)], ["DEF_duck_left%s_hold", Vector2(0.7, 0.9)], ["DEF_duck_right%s_hold", Vector2(-0.7, 0.9)],
]

static var _loops_patched := {}

var tree: AnimationTree
var player: AnimationPlayer
var skeleton: Skeleton3D
var _root: AnimationNodeBlendTree
var _playback: AnimationNodeStateMachinePlayback
var _slot_nodes: Array = []
var _guard_node: AnimationNodeAnimation

var _mix := 0.0
var _mix_target := 0.0
var _mix_rate := 10.0
var _act := 0.0
var _act_target := 0.0
var _act_rate := 10.0
var _guard := 0.0
var _guard_target := 0.0
var _guard_clip := &""
var _base_state := "Move"
var _blend_pos := Vector2.ZERO
var _cur_slot := 0
var inertia = null   ## Inertialize modifier: told about every clip change so the first jumpy frame is smoothed
var action_clip := &""
var action_length := 0.0
var lean_weight := 0.0
var _slot_counter_lean := [false, false]


## `parent` receives the AnimationTree; `model_root` is the instanced glb.
func setup(parent: Node, model_root: Node) -> void:
	player = model_root.find_child("AnimationPlayer", true, false)
	skeleton = model_root.find_child("Skeleton3D", true, false)
	_patch_loops(player)
	tree = AnimationTree.new()
	tree.name = "AnimationTree"
	_root = AnimationNodeBlendTree.new()
	_build()
	tree.tree_root = _root
	tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS
	parent.add_child(tree)
	tree.anim_player = tree.get_path_to(player)
	tree.root_node = tree.get_path_to(player.get_node(player.root_node))
	tree.active = true
	_playback = tree.get("parameters/Base/playback")
	_playback.start("Move")


static func _patch_loops(ap: AnimationPlayer) -> void:
	var key := ap.get_instance_id()
	var clips: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/clips.json"))["clips"]
	for n in ap.get_animation_list():
		var a := ap.get_animation(n)
		var want: bool = clips.get(n, {}).get("loop", false) or n.ends_with("_hold") or FORCE_LOOP.has(n)
		a.loop_mode = Animation.LOOP_LINEAR if want else Animation.LOOP_NONE
	_loops_patched[key] = true


func _space(kind: String) -> AnimationNodeBlendSpace2D:
	var bs := AnimationNodeBlendSpace2D.new()
	bs.min_space = Vector2(-1, -1)
	bs.max_space = Vector2(1, 1)
	bs.sync = true
	var i := 0
	for e in LOCO_SPACE[kind]:
		var an := AnimationNodeAnimation.new()
		an.animation = StringName(e[0])
		bs.add_blend_point(an, e[1], -1, StringName("p%d" % i))
		i += 1
	return bs


func _lean_space(block: bool) -> AnimationNodeBlendSpace2D:
	var bs := AnimationNodeBlendSpace2D.new()
	bs.min_space = Vector2(-1, -1)
	bs.max_space = Vector2(1, 1)
	bs.sync = true
	var sfx := "_block" if block else ""
	var idle := AnimationNodeAnimation.new()
	idle.animation = &"KB_Block" if block else &"KB_Idle_1"
	bs.add_blend_point(idle, Vector2.ZERO, -1, &"p0")
	var i := 1
	for e in LEAN_POINTS:
		var an := AnimationNodeAnimation.new()
		an.animation = StringName(String(e[0]) % sfx)
		bs.add_blend_point(an, e[1], -1, StringName("p%d" % i))
		i += 1
	return bs


## Switches the tree back on after a ragdoll fall (KO / knockdown / reset). Deactivating an AnimationTree resets its state
## machines: Base then sits in "Start" and (with set_locomotion only travelling on a change) never leaves it, so the body is
## posed by nothing but the rest (T) pose and the pose layers until something happens to travel it (rocked, ...).
## Re-fetch the playback object and put Base back on the locomotion blend space.
func reactivate() -> void:
	if inertia != null:
		inertia.reset()
		if inertia.get("post_peer") != null:
			inertia.post_peer.reset()
	tree.active = true
	_playback = tree.get("parameters/Base/playback")
	_playback.start("Move")
	_base_state = "Move"
	_mix = 0.0
	_act = 0.0
	_act_target = 0.0
	action_clip = &""
	_slot_counter_lean = [false, false]


func _build() -> void:
	var base := AnimationNodeStateMachine.new()
	base.add_node("Move", _space("stand"))
	base.add_node("Rocked", _space("stand"))
	for pair in [["Move", "Rocked"], ["Rocked", "Move"]]:
		var tr := AnimationNodeStateMachineTransition.new()
		tr.xfade_time = 0.25
		base.add_transition(pair[0], pair[1], tr)
	base.add_transition("Start", "Move", AnimationNodeStateMachineTransition.new())
	_root.add_node("Base", base, Vector2(0, 0))
	var bscale := AnimationNodeTimeScale.new()
	_root.add_node("BaseScale", bscale, Vector2(200, 0))
	_root.connect_node("BaseScale", 0, "Base")
	for i in 2:
		var sfx := "AB"[i]
		var an := AnimationNodeAnimation.new()
		an.animation = &"KB_Idle_1"
		_slot_nodes.append(an)
		_root.add_node("Slot" + sfx, an, Vector2(0, 150 + 150 * i))
		_root.add_node("Seek" + sfx, AnimationNodeTimeSeek.new(), Vector2(200, 150 + 150 * i))
		_root.add_node("Scale" + sfx, AnimationNodeTimeScale.new(), Vector2(400, 150 + 150 * i))
		_root.connect_node("Seek" + sfx, 0, "Slot" + sfx)
		_root.connect_node("Scale" + sfx, 0, "Seek" + sfx)
	var mix := AnimationNodeBlend2.new()
	_root.add_node("Mix", mix, Vector2(600, 250))
	_root.connect_node("Mix", 0, "ScaleA")
	_root.connect_node("Mix", 1, "ScaleB")
	_root.add_node("LeanFree", _lean_space(false), Vector2(0, 600))
	_root.add_node("LeanBlock", _lean_space(true), Vector2(0, 750))
	_root.add_node("LeanSel", AnimationNodeBlend2.new(), Vector2(300, 650))
	_root.connect_node("LeanSel", 0, "LeanFree")
	_root.connect_node("LeanSel", 1, "LeanBlock")
	_root.add_node("LeanMix", AnimationNodeBlend2.new(), Vector2(600, 450))
	_root.connect_node("LeanMix", 0, "BaseScale")
	_root.connect_node("LeanMix", 1, "LeanSel")
	var act := AnimationNodeBlend2.new()
	_root.add_node("Act", act, Vector2(800, 100))
	_root.connect_node("Act", 0, "LeanMix")
	_root.connect_node("Act", 1, "Mix")
	_guard_node = AnimationNodeAnimation.new()
	_guard_node.animation = &"KB_Block"
	_root.add_node("GuardAnim", _guard_node, Vector2(800, 300))
	var guard := AnimationNodeBlend2.new()
	guard.filter_enabled = true
	_root.add_node("Guard", guard, Vector2(1000, 150))
	_root.connect_node("Guard", 0, "Act")
	_root.connect_node("Guard", 1, "GuardAnim")
	_root.connect_node("output", 0, "Guard")
	# upper-body filter (resolved after the tree is parented; paths are relative to the model root)
	var model_root := player.get_node(player.root_node)
	var sk_path := String(model_root.get_path_to(skeleton))
	var upper := skeleton.find_bone("abdomenLower")
	for i in skeleton.get_bone_count():
		var p := i
		var inside := false
		while p >= 0:
			if p == upper:
				inside = true
				break
			p = skeleton.get_bone_parent(p)
		if inside:
			guard.set_filter_path(NodePath("%s:%s" % [sk_path, skeleton.get_bone_name(i)]), true)


func _has(clip: StringName) -> bool:
	return player.has_animation(clip)


func resolve(clip: String) -> StringName:
	var c: String = CLIP_ALIASES.get(clip, clip)
	return StringName(c)


func clip_length(clip: String) -> float:
	var c := resolve(clip)
	return player.get_animation(c).length if _has(c) else 0.0


## Locomotion: dir = (lateral, forward) in the fighter's own frame, magnitude 0..1; speed_scale for foot cadence.
func set_locomotion(local_dir: Vector2, speed_scale: float, rocked: bool, dt: float) -> void:
	_blend_pos = _blend_pos.lerp(local_dir.limit_length(1.0), 1.0 - exp(-9.0 * dt))
	tree.set("parameters/Base/Move/blend_position", _blend_pos)
	tree.set("parameters/Base/Rocked/blend_position", _blend_pos)
	tree.set("parameters/BaseScale/scale", clampf(speed_scale, 0.5, 1.8))
	var want := "Rocked" if rocked else "Move"
	if want != _base_state:
		_base_state = want
		_playback.travel(want)


## Play a one-shot action over the base layer. `duration` > 0 time-scales the clip to that length.
## `from_time` (clip seconds) seeks, `fade` is the crossfade in. `counter_lean` marks an authored counter
## clip that carries its own lean. Returns the played length in seconds.
func play_action(clip: String, duration := 0.0, fade := 0.10, from_time := 0.0, counter_lean := false) -> float:
	var c := resolve(clip)
	if not _has(c):
		push_warning("FighterAnimator: missing clip %s" % clip)
		return 0.0
	var clip_len := player.get_animation(c).length
	var slot := 0 if _mix > 0.5 else 1
	if _act < 0.05:
		slot = 0
		_mix = 0.0
	_cur_slot = slot
	(_slot_nodes[slot] as AnimationNodeAnimation).animation = c
	var suffix := "AB"[slot]
	var scale_v := 1.0
	var remaining := clip_len - from_time
	if duration > 0.0:
		scale_v = remaining / duration
	tree.set("parameters/Scale%s/scale" % suffix, scale_v)
	tree.set("parameters/Seek%s/seek_request" % suffix, from_time)
	_mix_target = float(slot)
	if inertia != null:
		inertia.trigger(minf(fade, 0.1) + 0.03)
	if _act < 0.05:
		_mix = float(slot)
	_mix_rate = 1.0 / maxf(fade, 0.01)
	_act_target = 1.0
	_act_rate = 1.0 / maxf(fade, 0.01)
	action_clip = c
	action_length = remaining / scale_v
	_slot_counter_lean[slot] = counter_lean
	return action_length


## Playback rate of the current action clip (clip seconds per real second); strikes retime the clip every tick.
func set_action_rate(rate: float) -> void:
	tree.set("parameters/Scale%s/scale" % "AB"[_cur_slot], rate)


func end_action(fade := 0.12) -> void:
	if inertia != null:
		inertia.trigger(minf(fade, 0.1) + 0.03)
	_act_target = 0.0
	_act_rate = 1.0 / maxf(fade, 0.01)
	action_clip = &""


func set_guard(clip: String, fade := 0.11) -> void:
	var prev_t := _guard_target
	var prev_c := _guard_clip
	if clip == "":
		_guard_target = 0.0
	else:
		var c := resolve(clip)
		if c != _guard_clip and _has(c):
			_guard_node.animation = c
			_guard_clip = c
		_guard_target = 1.0
	if inertia != null and (_guard_target != prev_t or _guard_clip != prev_c):
		inertia.trigger(minf(fade, 0.1) + 0.03)
	_guard_rate = 1.0 / maxf(fade, 0.01)


var _guard_rate := 9.0


func update(dt: float) -> void:
	_mix = move_toward(_mix, _mix_target, _mix_rate * dt)
	_act = move_toward(_act, _act_target, _act_rate * dt)
	_guard = move_toward(_guard, _guard_target, _guard_rate * dt)
	tree.set("parameters/Mix/blend_amount", _mix)
	tree.set("parameters/Act/blend_amount", _act)
	tree.set("parameters/Guard/blend_amount", _guard)


## Lean routing. The authored hold BlendSpaces remain in the tree for compatibility, but their poses are bypassed: the
## calibrated LeanPose modifier now owns free / blocked analog leans over the normal gait. The blend positions are still
## published so capture/debug tools can inspect them while the route stays at zero.
func set_lean(pos: Vector2, block: float) -> void:
	lean_weight = 0.0
	tree.set("parameters/LeanFree/blend_position", pos)
	tree.set("parameters/LeanBlock/blend_position", pos)
	tree.set("parameters/LeanSel/blend_amount", block)
	tree.set("parameters/LeanMix/blend_amount", lean_weight)


## Procedural lean weight while an action is overlaying the guard. Ordinary actions keep it at 1; an authored
## counter fades it out exactly as its own lean fades in, then back in as the clip returns to guard.
func action_lean_share() -> float:
	var embedded := lerpf(1.0 if _slot_counter_lean[0] else 0.0, 1.0 if _slot_counter_lean[1] else 0.0, _mix)
	return 1.0 - _act * embedded


func action_weight() -> float:
	return _act
