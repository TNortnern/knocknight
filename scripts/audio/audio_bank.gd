class_name AudioBank
extends Node3D
## Sound pools from data/sounds.json plus a few procedurally synthesised sounds
## (whoosh, bell, crowd bed, UI blips) for events that have no recorded file.
## Usage: bank.bind_match(match_node) after the match is in the tree.

const SOUNDS_JSON := "res://data/sounds.json"
const AUDIO_DIR := "res://assets/audio/"
const MIX_RATE := 22050
const MAX_VOICES := 24

var pools: Dictionary = {}
var _cache: Dictionary = {}
var _last: Dictionary = {}  # pool name -> last file
var _rng := RandomNumberGenerator.new()
var _match: Node
var _voices := 0
var _whooshes: Array[AudioStreamWAV] = []
var _bell: AudioStreamWAV
var _click: AudioStreamWAV
var _move: AudioStreamWAV
var _crowd_player: AudioStreamPlayer
var _crowd_swell := 0.0
var _bell_player: AudioStreamPlayer
var _ui_player: AudioStreamPlayer
var last_played: Array[String] = []  # debug / tests


func _ready() -> void:
	_rng.randomize()
	_load_pools()
	_synthesise()
	_bell_player = AudioStreamPlayer.new()
	_bell_player.stream = _bell
	_bell_player.volume_db = -8.0
	add_child(_bell_player)
	_ui_player = AudioStreamPlayer.new()
	_ui_player.volume_db = -10.0
	_ui_player.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_ui_player)


func _load_pools() -> void:
	var f := FileAccess.open(SOUNDS_JSON, FileAccess.READ)
	if f == null:
		push_warning("AudioBank: %s not found" % SOUNDS_JSON)
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary and (parsed as Dictionary).has("arrays"):
		pools = (parsed as Dictionary)["arrays"]


# --- public API --------------------------------------------------------------------------

func bind_match(m: Node) -> void:
	_match = m
	_voices = 0
	m.hit_landed.connect(_on_hit)
	m.whiffed.connect(_on_whiff)
	if m.has_signal("clash"):
		m.clash.connect(_on_clash)
	m.knockdown.connect(_on_knockdown)
	m.round_started.connect(_on_round_started)
	m.round_ended.connect(_on_round_ended)
	m.match_ended.connect(_on_match_ended)
	if m.has_signal("fighter_state_changed"):
		m.fighter_state_changed.connect(_on_state)
	start_crowd()


func start_crowd() -> void:
	if _crowd_player:
		if not _crowd_player.playing:
			_crowd_player.play()
		return
	_crowd_player = AudioStreamPlayer.new()
	_crowd_player.stream = _make_crowd()
	_crowd_player.volume_db = -34.0
	add_child(_crowd_player)
	_crowd_player.play()


func stop_all() -> void:
	if _crowd_player:
		_crowd_player.stop()


func ui_click() -> void:
	_ui_player.stream = _click
	_ui_player.play()


func ui_move() -> void:
	_ui_player.stream = _move
	_ui_player.play()


## Picks a random file from the pool, never the same twice in a row.
func pick(pool: String) -> String:
	var arr: Array = pools.get(pool, [])
	if arr.is_empty():
		return ""
	var last: String = _last.get(pool, "")
	var choice := ""
	for i in 8:
		choice = arr[_rng.randi() % arr.size()]
		if choice != last or arr.size() == 1:
			break
	if choice == last and arr.size() > 1:
		for c: String in arr:
			if c != last:
				choice = c
				break
	_last[pool] = choice
	return choice


func play_pool(pool: String, pos: Vector3, gain := 1.0, pitch := 1.0, jitter := 0.06) -> void:
	var file := pick(pool)
	if file == "":
		return
	var stream := _get_stream(file)
	if stream == null:
		return
	_play_at(stream, pos, gain, pitch * (1.0 + _rng.randf_range(-jitter, jitter)))
	last_played.append(file)
	if last_played.size() > 32:
		last_played.pop_front()


# --- internals ---------------------------------------------------------------------------

func _get_stream(file: String) -> AudioStream:
	if _cache.has(file):
		return _cache[file]
	var path := AUDIO_DIR + file
	var s: AudioStream = null
	if ResourceLoader.exists(path):
		s = load(path)
	_cache[file] = s
	return s


func _play_at(stream: AudioStream, pos: Vector3, gain: float, pitch: float) -> void:
	if _voices >= MAX_VOICES:
		return
	var p := AudioStreamPlayer3D.new()
	p.stream = stream
	p.volume_db = linear_to_db(clampf(gain, 0.02, 1.4))
	p.pitch_scale = pitch
	p.unit_size = 8.0
	p.max_distance = 60.0
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	p.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(p)
	p.global_position = pos
	_voices += 1
	p.finished.connect(func() -> void:
		_voices -= 1
		p.queue_free())
	p.play()


func _fighter_pos(index: int) -> Vector3:
	if _match and _match.has_method("get_fighters"):
		var fs: Array = _match.get_fighters()
		if index >= 0 and index < fs.size() and fs[index] is Node3D:
			return (fs[index] as Node3D).global_position + Vector3(0, 1.0, 0)
	return Vector3(0, 1.0, 0)


func _on_hit(_attacker: int, info: Dictionary) -> void:
	var pos: Vector3 = info.get("position", Vector3(0, 1.2, 0))
	var zone := String(info.get("zone", "head"))
	var strength := String(info.get("strength", "light"))
	var blocked := bool(info.get("blocked", false))
	var counter := bool(info.get("counter", false)) or bool(info.get("trade_won", false))
	var dmg := float(info.get("damage", 5.0))
	var gscale := 1.0 + 0.005 * minf(20.0, dmg)
	if bool(info.get("parry", false)):   # a light deflect: a high, short glove slap and a soft whoosh
		play_pool("gloveBlockSounds", pos, 0.42, 1.32)
		play_pool("gloveBlockSounds", pos, 0.22, 1.55)
		_swell(0.02)
		return
	if blocked:
		var g := (0.5 if strength == "light" else 0.7 if strength == "medium" else 0.95) * gscale
		play_pool("gloveBlockSounds", pos, g, 0.93)
		_swell(0.03)
		return
	var head := zone == "head"
	match strength:
		"heavy":
			if head:
				play_pool("headLightSounds", pos, 0.28 * gscale)
				play_pool("headMediumSounds", pos, 0.4 * gscale)
				play_pool("headHeavySounds", pos, 0.9 * gscale, 0.97)
			else:
				play_pool("bodyThudSounds", pos, 0.6 * gscale, 0.9)
				play_pool("headMediumSounds", pos, 0.3 * gscale, 0.92)
				play_pool("headHeavySounds", pos, 0.6 * gscale, 0.88)
			_swell(0.07)
		"medium":
			if head:
				play_pool("headLightSounds", pos, 0.46 * gscale)
				play_pool("headMediumSounds", pos, 0.64 * gscale)
			else:
				play_pool("bodyThudSounds", pos, 0.6 * gscale, 0.93)
				play_pool("headMediumSounds", pos, 0.45 * gscale, 0.93)
			_swell(0.05)
		_:
			if head:
				play_pool("headLightSounds", pos, 0.6 * gscale)
			else:
				play_pool("bodyThudSounds", pos, 0.58 * gscale)
			_swell(0.03)
	if counter:
		play_pool("critSounds", pos, 0.45, 0.95)
		_swell(0.04)


## Two straight punches met glove to glove (exchange): a dry double slap, higher and shorter than a block.
func _on_clash(pos: Vector3) -> void:
	play_pool("gloveBlockSounds", pos, 0.55, 1.18)
	play_pool("gloveBlockSounds", pos, 0.3, 1.38)
	_swell(0.02)


func _on_whiff(attacker: int, strike: String) -> void:
	var heavy := strike.contains("kick") or strike.contains("hook") or strike.contains("uppercut")
	var s := _whooshes[2 if heavy else _rng.randi() % 2]
	_play_at(s, _fighter_pos(attacker), 0.4 if not heavy else 0.55, 1.0 + _rng.randf_range(-0.08, 0.08))


func _on_knockdown(index: int) -> void:
	var pos := _fighter_pos(index)
	play_pool("headHeavySounds", pos, 0.8, 0.82)
	play_pool("bodyThudSounds", pos, 0.7, 0.8)
	_swell(0.1)


func _on_state(index: int, state: String) -> void:
	var s := state.to_lower()
	if s.contains("rock") or s.contains("stun") or s.contains("stagger"):
		play_pool("stunSounds", _fighter_pos(index), 0.9)
		play_pool("headHeavySounds", _fighter_pos(index), 0.5, 0.9)   # fatigue pass: the rock lands with weight
		play_pool("breathSounds", _fighter_pos(index), 0.25)
		_swell(0.06)


func _on_round_started(_r: int) -> void:
	ring_bell(1)


func _on_round_ended(_r: int) -> void:
	ring_bell(3)


func _on_match_ended(result: Dictionary) -> void:
	var m := String(result.get("method", ""))
	if m == "KO" or m == "TKO":
		var w := int(result.get("winner", -1))
		var victim := 1 - w if w in [0, 1] else 0
		var pos := _fighter_pos(victim)
		play_pool("koSounds", pos, 0.9)
		play_pool("headHeavySounds", pos, 0.7, 0.85)
		_swell(0.2)
	elif m == "Decision" or m == "Draw":
		ring_bell(3)


func ring_bell(times: int) -> void:
	for i in times:
		if i == 0:
			_bell_player.play()
		else:
			get_tree().create_timer(0.62 * i).timeout.connect(func() -> void:
				if is_instance_valid(_bell_player):
					_bell_player.play())


func _swell(amount: float) -> void:
	_crowd_swell = minf(_crowd_swell + amount, 0.3)


var _gasp_t := [0.0, 0.0]


func _process(delta: float) -> void:
	_gasp(delta)
	if _crowd_player:
		_crowd_swell = move_toward(_crowd_swell, 0.0, delta * 0.12)
		_crowd_player.volume_db = linear_to_db(0.02 + _crowd_swell * 0.6)


## Fatigue pass: a gassed fighter heaves audibly (the pool is the same one the rocked sound uses).
func _gasp(delta: float) -> void:
	if _match == null or not is_instance_valid(_match) or not _match.has_method("get_fighters"):
		return
	var fs: Array = _match.get_fighters()
	for i in mini(2, fs.size()):
		var lvl: Variant = (fs[i] as Object).get("fatigue")
		if lvl == null or float(lvl) < 0.5:
			_gasp_t[i] = 1.2
			continue
		_gasp_t[i] -= delta
		if _gasp_t[i] <= 0.0:
			_gasp_t[i] = lerpf(2.4, 1.3, float(lvl))
			play_pool("breathSounds", _fighter_pos(i), 0.3 + 0.3 * float(lvl))


# --- synthesis ---------------------------------------------------------------------------

func _wav(samples: PackedFloat32Array, loop := false) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = MIX_RATE
	w.stereo = false
	w.data = data
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = samples.size()
	return w


func _synthesise() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	# Whooshes: band-passed noise with a rising then falling centre frequency
	for v in 3:
		var dur: float = [0.16, 0.2, 0.28][v]
		var n := int(MIX_RATE * dur)
		var out := PackedFloat32Array()
		out.resize(n)
		var lp := 0.0
		var lp2 := 0.0
		for i in n:
			var t := float(i) / n
			var env := sin(PI * t) * sin(PI * t)
			var cutoff := lerpf(0.12, 0.45, sin(PI * t * 0.9)) * (1.0 - 0.25 * v)
			var x := rng.randf_range(-1.0, 1.0)
			lp += (x - lp) * cutoff
			lp2 += (lp - lp2) * cutoff
			out[i] = (lp - lp2) * env * 3.2
		_whooshes.append(_wav(out))
	# Bell: inharmonic partials with exponential decay
	var bn := int(MIX_RATE * 2.4)
	var bell := PackedFloat32Array()
	bell.resize(bn)
	var partials := [[540.0, 1.0, 2.2], [1130.0, 0.6, 2.6], [1620.0, 0.45, 3.4], [2480.0, 0.3, 4.4], [3410.0, 0.18, 6.0]]
	for i in bn:
		var t := float(i) / MIX_RATE
		var s := 0.0
		for p: Array in partials:
			s += sin(TAU * p[0] * t) * p[1] * exp(-t * p[2])
		var attack := minf(1.0, t / 0.003)
		bell[i] = s * 0.3 * attack
	_bell = _wav(bell)
	# UI blips
	var cn := int(MIX_RATE * 0.09)
	var click := PackedFloat32Array()
	click.resize(cn)
	for i in cn:
		var t := float(i) / MIX_RATE
		click[i] = (sin(TAU * 880.0 * t) * 0.6 + sin(TAU * 1320.0 * t) * 0.3) * exp(-t * 45.0)
	_click = _wav(click)
	var mn := int(MIX_RATE * 0.04)
	var mv := PackedFloat32Array()
	mv.resize(mn)
	for i in mn:
		var t := float(i) / MIX_RATE
		mv[i] = sin(TAU * 520.0 * t) * 0.5 * exp(-t * 90.0)
	_move = _wav(mv)


func _make_crowd() -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var n := MIX_RATE * 6
	var out := PackedFloat32Array()
	out.resize(n)
	var lp := 0.0
	var lp2 := 0.0
	for i in n:
		var x := rng.randf_range(-1.0, 1.0)
		lp += (x - lp) * 0.09
		lp2 += (lp - lp2) * 0.05
		var swell := 0.75 + 0.25 * sin(TAU * i / n * 3.0)
		out[i] = lp2 * 5.0 * swell
	# crossfade the tail into the head so the loop is seamless
	var fade := 2000
	for i in fade:
		var k := float(i) / fade
		out[i] = out[i] * k + out[n - fade + i] * (1.0 - k)
	return _wav(out.slice(0, n - fade), true)
