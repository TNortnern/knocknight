class_name Main
extends Node
## Game shell: menu -> setup -> match (+ arena, camera, HUD, audio) -> results -> menu.
## Loads res://scenes/match.tscn when it exists, otherwise the stub in tests/stubs.

const MATCH_PATH := "res://scenes/match.tscn"
const STUB_PATH := "res://tests/stubs/stub_match.tscn"
const ARENAS := {
	"ring": "res://scenes/arena.tscn",
	"octagon": "res://scenes/arena_octagon.tscn",
}
var results_delay := 3.4
var ko_results_delay := 5.0

enum State { MENU, SETUP, FIGHT, PAUSED, RESULTS }

var state: int = State.MENU
var current_match: Node
var current_arena: Node
var current_camera: FightCamera
var last_config: Dictionary = {}
var last_result: Dictionary = {}
var audio: AudioBank
## Set to the stub path to force the stub (tests).
var force_stub := false

var _title: TitleMenu
var _setup: SetupScreen
var _hud: Hud
var _pause: PauseMenu
var _results: ResultsScreen
var _match_token := 0

@onready var world: Node = $World
@onready var ui: CanvasLayer = $UI


func _ready() -> void:
	var win := get_window()
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	win.content_scale_size = Vector2i(1600, 900)
	ui.process_mode = Node.PROCESS_MODE_ALWAYS

	audio = AudioBank.new()
	audio.name = "Audio"
	audio.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(audio)

	_title = load("res://scenes/ui/title_menu.tscn").instantiate()
	_setup = load("res://scenes/ui/setup_screen.tscn").instantiate()
	_hud = load("res://scenes/ui/hud.tscn").instantiate()
	_pause = load("res://scenes/ui/pause_menu.tscn").instantiate()
	_results = load("res://scenes/ui/results_screen.tscn").instantiate()
	for n: Control in [_title, _setup, _hud, _pause, _results]:
		ui.add_child(n)
		n.hide()
	_title.mode_chosen.connect(_on_mode_chosen)
	_title.quit_requested.connect(func() -> void: get_tree().quit())
	_setup.start_requested.connect(start_match)
	_setup.back_requested.connect(show_menu)
	_pause.resume_requested.connect(resume)
	_pause.restart_requested.connect(func() -> void: start_match(last_config))
	_pause.quit_requested.connect(show_menu)
	_results.rematch_requested.connect(func() -> void: start_match(last_config))
	_results.menu_requested.connect(show_menu)
	get_viewport().gui_focus_changed.connect(func(_c: Control) -> void:
		if state != State.FIGHT:
			audio.ui_move())
	show_menu()


func get_state_name() -> String:
	return State.keys()[state]


func _show_only(node: Control) -> void:
	for n: Control in [_title, _setup, _hud, _pause, _results]:
		n.visible = n == node


# --- flow --------------------------------------------------------------------------------

func show_menu() -> void:
	_end_match()
	get_tree().paused = false
	state = State.MENU
	_show_only(_title)
	_title.focus_first()


func _on_mode_chosen(mode: String) -> void:
	audio.ui_click()
	_setup.configure(mode)
	state = State.SETUP
	_show_only(_setup)
	_setup.focus_first()


func start_match(config: Dictionary) -> void:
	audio.ui_click()
	_end_match()
	get_tree().paused = false
	last_config = config.duplicate(true)
	_match_token += 1
	var path := STUB_PATH if (force_stub or not ResourceLoader.exists(MATCH_PATH)) else MATCH_PATH
	var m: Node = (load(path) as PackedScene).instantiate()
	if m.has_method("setup"):
		m.setup(config)
	# Wire listeners before the match enters the tree so nothing emitted in its _ready is missed.
	audio.bind_match(m)
	_hud.bind_match(m, config)
	m.match_ended.connect(_on_match_ended.bind(_match_token))
	current_match = m
	world.add_child(m)

	var arena_path: String = ARENAS.get(String(config.get("arena", "ring")), ARENAS["ring"])
	current_arena = (load(arena_path) as PackedScene).instantiate()
	var slot: Node = m.get_node_or_null("ArenaSlot")
	(slot if slot else m).add_child(current_arena)
	var placeholder := m.get_node_or_null("PlaceholderArena")
	if placeholder:
		placeholder.queue_free()
	for c in m.find_children("*", "Camera3D", true, false):
		(c as Camera3D).current = false

	current_camera = FightCamera.new()
	current_camera.name = "FightCamera"
	if current_arena is Arena:
		current_camera.arena = current_arena
	world.add_child(current_camera)
	var fighters: Array = m.get_fighters()
	if fighters.size() >= 2:
		current_camera.track(fighters[0], fighters[1])
	current_camera.bind_match(m)
	current_camera.make_current()

	state = State.FIGHT
	_show_only(_hud)


func _end_match() -> void:
	_match_token += 1
	if current_camera and is_instance_valid(current_camera):
		current_camera.queue_free()
	if current_match and is_instance_valid(current_match):
		current_match.queue_free()
	current_camera = null
	current_match = null
	current_arena = null
	if audio:
		audio.stop_all()


func _on_match_ended(result: Dictionary, token: int) -> void:
	if token != _match_token:
		return
	last_result = result
	var method := String(result.get("method", ""))
	var delay := ko_results_delay if (method == "KO" or method == "TKO") else results_delay
	await get_tree().create_timer(delay).timeout
	if token != _match_token:
		return
	show_results()


func show_results() -> void:
	var names: Array = []
	if current_match and is_instance_valid(current_match):
		for f: Object in current_match.get_fighters():
			names.append(String(f.get("display_name")))
	if names.size() < 2:
		names = ["P1", "P2"]
	get_tree().paused = false
	state = State.RESULTS
	_results.show_result(last_result, names, last_config)
	_show_only(_results)


func pause() -> void:
	if state != State.FIGHT:
		return
	state = State.PAUSED
	get_tree().paused = true
	_pause.show()
	_pause.focus_first()


func resume() -> void:
	if state != State.PAUSED:
		return
	get_tree().paused = false
	state = State.FIGHT
	_pause.hide()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3 and current_match != null:
		current_match.toggle_debug_boxes()   # hit / hurt / guard volume overlay
		get_viewport().set_input_as_handled()
		return
	var is_pause_key: bool = (event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE) \
		or (event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_START)
	match state:
		State.FIGHT:
			if is_pause_key:
				pause()
				get_viewport().set_input_as_handled()
		State.PAUSED:
			if event is InputEventJoypadButton and is_pause_key:
				resume()
				get_viewport().set_input_as_handled()
		State.SETUP:
			if event.is_action_pressed("ui_cancel"):
				show_menu()
				get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and state == State.FIGHT:
		pause()
