class_name HudBar
extends Control
## Slanted resource bar with a smoothed fill and a delayed "damage trail".

@export var fill_color := Color(0.94, 0.91, 0.87)
@export var trail_color := Color(0.88, 0.27, 0.22)
@export var back_color := Color(0.02, 0.022, 0.028, 0.72)
@export var mirrored := false
@export var slant := 12.0
@export var caption := ""

var target := 1.0
var shown := 1.0
var trail := 1.0
var _hold := 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_target(v: float, snap := false) -> void:
	v = clampf(v, 0.0, 1.0)
	if v < target - 0.0005:
		_hold = 0.55
	target = v
	if snap:
		shown = v
		trail = v
		queue_redraw()


func _process(delta: float) -> void:
	var changed := false
	if absf(shown - target) > 0.0005:
		shown = lerpf(shown, target, 1.0 - exp(-14.0 * delta))
		changed = true
	if trail > shown:
		_hold -= delta
		if _hold <= 0.0:
			trail = move_toward(trail, shown, delta * 0.35)
			changed = true
	elif trail < shown:
		trail = shown
		changed = true
	if changed:
		queue_redraw()


func _poly(frac: float) -> PackedVector2Array:
	var w := size.x
	var h := size.y
	var s := minf(slant, h * 0.9)
	var fw := frac * (w - s)
	var pts := PackedVector2Array([Vector2(s, 0), Vector2(s + fw, 0), Vector2(fw, h), Vector2(0, h)])
	if mirrored:
		for i in pts.size():
			pts[i].x = w - pts[i].x
	return pts


func _draw() -> void:
	draw_colored_polygon(_poly(1.0), back_color)
	if trail > shown + 0.001:
		draw_colored_polygon(_poly(trail), trail_color)
	if shown > 0.002:
		draw_colored_polygon(_poly(shown), fill_color)
		# subtle highlight on the top half
		var hl := _poly(shown)
		var mid := size.y * 0.5
		var top := PackedVector2Array([hl[0], hl[1], Vector2(lerpf(hl[1].x, hl[2].x, 0.5), mid), Vector2(lerpf(hl[0].x, hl[3].x, 0.5), mid)])
		draw_colored_polygon(top, Color(1, 1, 1, 0.16))
	var outline := _poly(1.0)
	outline.append(outline[0])
	draw_polyline(outline, Color(1, 1, 1, 0.28), 1.5, true)
	if caption != "":
		var font := get_theme_default_font()
		var fs := 13
		var tw := font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var x := size.x - tw - slant - 6.0 if mirrored else slant + 8.0
		var at := Vector2(x, size.y * 0.5 + fs * 0.36)
		draw_string_outline(font, at, caption, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 4, Color(0, 0, 0, 0.85))
		draw_string(font, at, caption, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.96, 0.93, 0.88, 0.9))
