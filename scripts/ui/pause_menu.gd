class_name PauseMenu
extends Control
## Pause overlay. Runs while the tree is paused (PROCESS_MODE_ALWAYS).

signal resume_requested
signal restart_requested
signal quit_requested

var _buttons: Array = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.62)
	UICommon.full_rect(dim)
	add_child(dim)
	var center := CenterContainer.new()
	UICommon.full_rect(center)
	add_child(center)
	var panel := PanelContainer.new()
	center.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	col.custom_minimum_size = Vector2(440, 0)
	panel.add_child(col)
	var cap := UICommon.label("FIGHT PAUSED", "CaptionLabel")
	cap.add_theme_color_override("font_color", UICommon.AMBER)
	col.add_child(cap)
	var title := UICommon.label("PAUSE", "HeadingLabel")
	title.add_theme_font_size_override("font_size", 78)
	title.add_theme_color_override("font_color", UICommon.IVORY)
	col.add_child(title)
	var sp := Control.new()
	sp.custom_minimum_size = Vector2(0, 8)
	col.add_child(sp)
	for it in [["RESUME", "BtnResume", resume_requested], ["RESTART BOUT", "BtnRestart", restart_requested], ["QUIT TO MENU", "BtnQuit", quit_requested]]:
		var b := UICommon.button(it[0], it[1], 440)
		var sig: Signal = it[2]
		b.pressed.connect(func() -> void: sig.emit())
		col.add_child(b)
		_buttons.append(b)
	UICommon.chain(_buttons)
	var hint := UICommon.label("ESC / START  resume", "CaptionLabel")
	col.add_child(hint)
	visibility_changed.connect(func() -> void:
		if is_visible_in_tree():
			focus_first())


func focus_first() -> void:
	if _buttons.size() > 0 and is_inside_tree():
		(_buttons[0] as Button).grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		resume_requested.emit()
		get_viewport().set_input_as_handled()
