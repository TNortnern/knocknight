extends Node3D
## Stub with the same API as the real Match so presentation code can be built and tested
## without the fight core. Emits fake signals on demand (see fake_* helpers).

signal round_started(round: int)
signal round_ended(round: int)
signal match_ended(result: Dictionary)
signal timer_changed(seconds_left: float)
signal hit_landed(attacker_index: int, info: Dictionary)
signal whiffed(attacker_index: int, strike: String)
signal knockdown(index: int)
signal count_tick(index: int, n: int)
signal fighter_state_changed(index: int, state: String)

const FighterStub := preload("res://tests/stubs/stub_fighter.gd")

var config: Dictionary = {}
var fighters: Array = []
var round_number := 0
var seconds_left := 180.0
var auto_demo := false
var _t := 0.0
var _spawned := false


func setup(p_config: Dictionary) -> void:
	config = p_config
	seconds_left = float(config.get("round_seconds", 180))


func get_fighters() -> Array:
	return fighters


func _enter_tree() -> void:
	if _spawned:
		return
	_spawned = true
	var names := ["Viper", "Anvil"]
	var tints := [Color(0.78, 0.18, 0.15), Color(0.2, 0.4, 0.8)]
	for i in 2:
		var f := FighterStub.new()
		f.name = "Fighter%d" % (i + 1)
		f.setup(names[i], tints[i])
		f.position = Vector3(-1.15 if i == 0 else 1.15, 0, 0)
		f.rotation.y = PI / 2.0 if i == 0 else -PI / 2.0
		add_child(f)
		fighters.append(f)


func _ready() -> void:
	round_number = 1
	round_started.emit(1)
	timer_changed.emit(seconds_left)


func _process(delta: float) -> void:
	_t += delta
	if auto_demo and fighters.size() == 2:
		fighters[0].position.x = -1.15 + sin(_t * 0.7) * 0.5
		fighters[1].position.x = 1.15 + sin(_t * 0.5) * 0.4
		fighters[0].position.z = sin(_t * 0.3) * 0.8
	seconds_left = maxf(0.0, seconds_left - delta)
	timer_changed.emit(seconds_left)


func fake_hit(attacker: int, strength: String, zone := "head", blocked := false, damage := 8.0) -> void:
	var victim: Node3D = fighters[1 - attacker]
	var info := {"zone": zone, "blocked": blocked, "damage": damage, "strength": strength,
		"position": victim.global_position + Vector3(0, 1.4 if zone == "head" else 1.0, 0),
		"counter": false, "strike": "jab"}
	hit_landed.emit(attacker, info)
	if not blocked:
		victim.set_stat("health", maxf(0.0, victim.health - damage))


func fake_end(winner: int, method: String) -> void:
	match_ended.emit({"winner": winner, "method": method})
