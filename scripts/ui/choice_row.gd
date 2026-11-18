class_name ChoiceRow
extends Button
## "Label        < value >" row. Left/Right (keys, D-pad, stick) change the value,
## clicking or Enter/A cycles forward.

signal changed(value: Variant)

var title := ""
var options: Array = []  # Array of {"label": String, "value": Variant}
var index := 0
var _title_label: Label
var _value_label: Label


func _init() -> void:
	focus_mode = Control.FOCUS_ALL
	custom_minimum_size = Vector2(0, 62)
	alignment = HORIZONTAL_ALIGNMENT_LEFT


func _ready() -> void:
	var box := HBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UICommon.full_rect(box)
	box.offset_left = 26
	box.offset_right = -22
	add_child(box)
	_title_label = Label.new()
	_title_label.text = title
	_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.add_theme_font_size_override("font_size", 24)
	_title_label.add_theme_color_override("font_color", Color(0.94, 0.91, 0.87, 0.72))
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	box.add_child(_title_label)
	_value_label = Label.new()
	_value_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_value_label.add_theme_font_size_override("font_size", 28)
	box.add_child(_value_label)
	pressed.connect(func() -> void: cycle(1))
	mouse_entered.connect(func() -> void:
		if is_visible_in_tree():
			grab_focus())
	focus_entered.connect(_refresh)
	focus_exited.connect(_refresh)
	_refresh()


func setup(p_title: String, p_options: Array, p_index := 0) -> ChoiceRow:
	title = p_title
	options = p_options
	index = clampi(p_index, 0, maxi(0, p_options.size() - 1))
	if _title_label:
		_title_label.text = title
		_refresh()
	return self


func set_options(p_options: Array, keep_value := true) -> void:
	var old: Variant = value()
	options = p_options
	index = 0
	if keep_value:
		for i in options.size():
			if options[i]["value"] == old:
				index = i
	_refresh()


func value() -> Variant:
	if options.is_empty():
		return null
	return options[index]["value"]


func select_value(v: Variant) -> void:
	for i in options.size():
		if options[i]["value"] == v:
			index = i
	_refresh()


func cycle(step: int) -> void:
	if options.size() < 2:
		return
	index = (index + step + options.size()) % options.size()
	_refresh()
	changed.emit(value())


func _gui_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_left"):
		cycle(-1)
		accept_event()
	elif event.is_action_pressed("ui_right"):
		cycle(1)
		accept_event()


func _refresh() -> void:
	if _value_label == null or options.is_empty():
		return
	var focused := has_focus()
	var text := String(options[index]["label"])
	_value_label.text = ("<  %s  >" % text) if (focused and options.size() > 1) else text
	_value_label.add_theme_color_override("font_color", UICommon.AMBER if focused else UICommon.IVORY)


func refresh() -> void:
	if _title_label:
		_title_label.text = title
	_refresh()
