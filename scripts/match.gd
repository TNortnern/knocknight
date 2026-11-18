class_name Match
extends Node3D
## Owns the two fighters and the MatchState: rounds, timer, knockdown freeze, KO/TKO/decision.
## Integration contract (see scenes/main.tscn / scripts/main.gd): setup(config) -> add to tree -> get_fighters().

signal round_started(round: int)
signal round_ended(round: int)
signal match_ended(result: Dictionary)
signal timer_changed(seconds_left: float)
signal hit_landed(attacker_index: int, info: Dictionary)
signal whiffed(attacker_index: int, strike: String)
signal clash(position: Vector3)   ## two straight punches met glove to glove (exchange)
signal knockdown(index: int)
signal count_tick(index: int, n: int)
signal fighter_state_changed(index: int, state: String)
signal referee_break()   ## the pair was locked chest to chest too long: the referee separates them
signal fight_resumed()   ## a knockdown count ended and the downed fighter is back on his feet

const FIGHTER_SCENE := preload("res://scenes/fighter.tscn")
const NeutralCorner := preload("res://scripts/fighter/neutral_corner.gd")
const ImpactFx := preload("res://scripts/fx/impact_fx.gd")
const SPAWN_X := 1.15
const RING_HALF := 3.2

var config: Dictionary = {}
var fighters: Array = []
var ms := MatchState.new()
var debug_boxes := false   ## F3: draw every hit / hurt / guard volume and flash the contact point of each blow
var intro_delay := 1.2       ## fighters held in their corners (banner ROUND n / FIGHT!) before the clock starts
var end_delay := 3.7
var intermission := 7.1
var decision_delay := 2.1
var round_end_delay := 2.0
var _started := false
var _intro_left := 0.0
var _timer_int := -1
var _ko_hold := 0.0
var _ended := false
var _pending := ""      ## "intermission" | "decision" | "ko"
var _pending_t := 0.0
var _fighters_node: Node3D
var _victor: Fighter
var _was_acute := false


func setup(p_config: Dictionary) -> void:
	config = p_config.duplicate(true)
	_build_fighters()


func get_fighters() -> Array:
	return fighters


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	if fighters.is_empty():
		_build_fighters()
	_fighters_node = Node3D.new()
	_fighters_node.name = "Fighters"
	add_child(_fighters_node)
	for f in fighters:
		_fighters_node.add_child(f)
	_started = true
	_start_bout()


func _build_fighters() -> void:
	if not fighters.is_empty():
		for f in fighters:
			f.queue_free()
		fighters.clear()
	var mode: String = config.get("mode", "exhibition")
	var rules: String = config.get("rules", "kickboxing")
	var diff: String = config.get("cpu_difficulty", "normal")
	var practice := mode != "exhibition"
	var models := [config.get("p1_model", "viper"), config.get("p2_model", "anvil")]
	var ctrls := [config.get("p1_controller", "human"), config.get("p2_controller", "cpu")]
	if mode == "training":
		ctrls[1] = "dummy"
	for i in 2:
		var f: Fighter = FIGHTER_SCENE.instantiate()
		f.model = models[i]
		f.player_index = i
		f.controller = ctrls[i]
		f.movement_mode = String(config.get("p%d_movement_mode" % (i + 1), config.get("movement_mode", GameSettings.DEFAULT_MODE)))
		f.rules = rules
		f.difficulty = diff
		f.practice = practice
		f.stats.practice = practice
		f.dummy_mode = config.get("dummy_mode", "stationary")
		f.debug_boxes = debug_boxes
		f.position = Vector3(-SPAWN_X if i == 0 else SPAWN_X, 0.0, 0.0)
		f.rotation.y = PI * 0.5 if i == 0 else -PI * 0.5
		if mode == "training":
			f.stats.infinite_stamina = true
		fighters.append(f)
	fighters[0].foe = fighters[1]
	fighters[1].foe = fighters[0]
	for f in fighters:
		f.hit_landed.connect(_on_hit)
		f.clashed.connect(func(_o, pos): clash.emit(pos))
		f.whiffed.connect(_on_whiff)
		f.knocked_down.connect(_on_knocked_down)
		f.count_tick.connect(_on_count)
		f.state_changed.connect(_on_state)
		f.got_ko.connect(_on_ko)
	fighters[0].bc.referee_break.connect(func() -> void: referee_break.emit())   # the pair shares one break
	if mode == "training":
		fighters[1].stats.infinite_stamina = true


func _start_bout() -> void:
	var mode: String = config.get("mode", "exhibition")
	var rounds: int = int(config.get("rounds", 1 if mode != "exhibition" else 3))
	var secs: float = float(config.get("round_seconds", 180.0))
	if mode != "exhibition":
		intro_delay = 0.8
	if config.has("intro_delay"):
		intro_delay = config["intro_delay"]
	if config.has("end_delay"):
		end_delay = config["end_delay"]
	if config.has("intermission"):
		intermission = config["intermission"]
	ms.configure(rounds, secs, mode != "exhibition")
	_begin_round()


func _begin_round() -> void:
	if ms.round > 0:
		for f in fighters:
			f.stats.rehab()
	for i in 2:
		var f: Fighter = fighters[i]
		f.reset_for_round(Vector3(-SPAWN_X if i == 0 else SPAWN_X, 0.0, 0.0), ms.round == 0)
		f.rotation.y = PI * 0.5 if i == 0 else -PI * 0.5
		f.input_locked = true
		f.buffer.clear()
	ms.begin_round()
	ms.phase = MatchState.Phase.PRE
	_intro_left = intro_delay
	_pending = ""
	_victor = null
	_timer_int = -1
	round_started.emit(ms.round)
	_emit_timer(true)


func restart() -> void:
	ms = MatchState.new()
	_ended = false
	_start_bout()


func _emit_timer(force := false) -> void:
	var secs := ceili(ms.time_left)
	if force or secs != _timer_int:
		_timer_int = secs
		timer_changed.emit(ms.time_left)


func _physics_process(dt: float) -> void:
	if not _started or _ended or fighters.size() < 2:
		return
	var a: Fighter = fighters[0]
	var b: Fighter = fighters[1]
	# --- knockdown freeze: the other fighter is held while someone is going through FALL/COUNT/GETUP
	var acute_a := a.is_acute_down()
	var acute_b := b.is_acute_down()
	a.frozen = acute_b and not acute_a
	b.frozen = acute_a and not acute_b
	# referee: the standing fighter goes to a neutral corner for the count
	a.corner_target = _referee_spot(a, b) if a.frozen else Vector3.INF
	b.corner_target = _referee_spot(b, a) if b.frozen else Vector3.INF
	var acute_now := acute_a or acute_b
	if _was_acute and not acute_now and not a.state == Fighter.State.DOWN and not b.state == Fighter.State.DOWN:
		fight_resumed.emit()
	_was_acute = acute_now
	match ms.phase:
		MatchState.Phase.PRE:
			# round intro: both fighters stand frozen in their corners while the banner plays
			_intro_left -= dt
			if _intro_left <= 0.0:
				ms.phase = MatchState.Phase.FIGHT
				for f in fighters:
					f.input_locked = false
		MatchState.Phase.FIGHT:
			if acute_a or acute_b:
				return
			if ms.tick(dt):
				_time_up()
			_emit_timer()
			_check_ko()
		MatchState.Phase.ROUND_END:
			_pending_t += dt
			if _pending == "ko":
				if _victor != null and _pending_t >= 1.2:
					_victor.start_victory()
					_victor = null
				if _pending_t >= end_delay:
					_finish(ms.result)
			elif _pending == "intermission" and _pending_t >= intermission:
				_begin_round()
			elif _pending == "decision" and _pending_t >= decision_delay:
				_finish(MatchState.decide(a.stats, b.stats))


## Where the standing fighter waits: the neutral corner for the count, back towards his own side of the ring
## while the downed fighter gets up (so the camera and the fight resume from a normal arrangement).
func _referee_spot(standing: Fighter, downed: Fighter) -> Vector3:
	if downed.state == Fighter.State.GETUP:
		return Vector3(-SPAWN_X if standing.player_index == 0 else SPAWN_X, 0.0, 0.0)
	return NeutralCorner.pick(standing.global_position, downed.global_position)


func _check_ko() -> void:
	var a: Fighter = fighters[0]
	var b: Fighter = fighters[1]
	var a_down := a.state == Fighter.State.DOWN
	var b_down := b.state == Fighter.State.DOWN
	if not a_down and not b_down:
		return
	var res := {}
	if a_down and b_down:
		res = {"winner": -1, "method": "Draw", "double_ko": true}
	else:
		var loser: Fighter = a if a_down else b
		var winner: Fighter = b if a_down else a
		res = {"winner": winner.player_index, "method": loser.ko_method if loser.ko_method != "" else "KO"}
		_victor = winner
	ms.result = res
	_pending = "ko"
	_pending_t = 0.0
	ms.phase = MatchState.Phase.ROUND_END
	for f in fighters:
		f.input_locked = true
	round_ended.emit(ms.round)


func _time_up() -> void:
	for f in fighters:
		f.input_locked = true
	ms.phase = MatchState.Phase.ROUND_END
	_pending_t = 0.0
	round_ended.emit(ms.round)
	_pending = "decision" if (ms.practice or ms.is_last_round()) else "intermission"


func _finish(result: Dictionary) -> void:
	if _ended:
		return
	_ended = true
	ms.phase = MatchState.Phase.MATCH_END
	var res := result.duplicate()
	if ms.practice:
		res["session"] = true
	var w: int = res.get("winner", -1)
	if res.get("method", "") != "Draw":
		for f in fighters:
			if f.state != Fighter.State.DOWN:
				if f.player_index == w:
					f.start_victory()
				else:
					f.start_loss_pose()
	res["round"] = ms.round
	res["scores"] = res.get("scores", [fighters[0].stats.total_max(), fighters[1].stats.total_max()])
	match_ended.emit(res)


# ---- fighter signal relays
func _on_hit(att: Fighter, info: Dictionary) -> void:
	hit_landed.emit(att.player_index, info)


func _on_whiff(att: Fighter, strike: String) -> void:
	whiffed.emit(att.player_index, strike)


func _on_knocked_down(f: Fighter) -> void:
	ImpactFx.slowmo(get_tree(), 0.3, 0.25)   # impact dip, restored by a real-time timer
	knockdown.emit(f.player_index)


func _on_count(f: Fighter, n: int) -> void:
	count_tick.emit(f.player_index, n)


func _on_state(f: Fighter, s: String) -> void:
	fighter_state_changed.emit(f.player_index, s)


func _on_ko(_f: Fighter, _method: String) -> void:
	ImpactFx.slowmo(get_tree(), 0.3, 0.4)


func _exit_tree() -> void:
	ImpactFx.restore()


## F3 (scripts/main.gd): show / hide the hit volumes and contact flashes of both fighters.
func toggle_debug_boxes() -> void:
	debug_boxes = not debug_boxes
	for f in fighters:
		f.set_debug_boxes(debug_boxes)
