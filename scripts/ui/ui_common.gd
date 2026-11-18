class_name UICommon
extends RefCounted
## Shared palette and small construction helpers for the menu screens.

const THEME_PATH := "res://scenes/ui/theme.tres"
const IVORY := Color(0.94, 0.91, 0.87)
const AMBER := Color(1.0, 0.78, 0.34)
const RED := Color(0.88, 0.27, 0.22)
const BLUE := Color(0.23, 0.5, 0.83)
const GREEN := Color(0.4, 0.82, 0.5)
const GUARD_BLUE := Color(0.4, 0.65, 0.96)
const BG := Color(0.06, 0.065, 0.075)

const ART := {
	"title": "res://assets/ui/ui42/main-menu-art.webp",
	"exhibition": "res://assets/ui/ui42/exhibition-art.webp",
	"sparring": "res://assets/ui/ui42/sparring-art.webp",
	"training": "res://assets/ui/ui42/training-art.webp",
}


static func art(key: String) -> Texture2D:
	return load(ART.get(key, ART["title"])) as Texture2D


static func full_rect(c: Control) -> void:
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


static func art_rect(key: String) -> TextureRect:
	var t := TextureRect.new()
	t.texture = art(key)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	full_rect(t)
	return t


## Horizontal gradient, opaque dark on the left fading to transparent.
static func side_shade(strength := 0.96, width_fraction := 0.75) -> TextureRect:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, width_fraction * 0.55, width_fraction, 1.0])
	g.colors = PackedColorArray([
		Color(0.03, 0.032, 0.04, strength), Color(0.03, 0.032, 0.04, strength * 0.82),
		Color(0.03, 0.032, 0.04, 0.0), Color(0.03, 0.032, 0.04, 0.0)])
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(1, 0)
	gt.width = 512
	gt.height = 4
	var r := TextureRect.new()
	r.texture = gt
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_SCALE
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	full_rect(r)
	return r


static func bottom_shade() -> TextureRect:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.6, 1.0])
	g.colors = PackedColorArray([Color(0, 0, 0, 0), Color(0, 0, 0, 0.0), Color(0, 0, 0, 0.7)])
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(0, 1)
	gt.width = 4
	gt.height = 256
	var r := TextureRect.new()
	r.texture = gt
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_SCALE
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	full_rect(r)
	return r


static func label(text: String, variation := "", align := HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	if variation != "":
		l.theme_type_variation = variation
	l.horizontal_alignment = align
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


static func button(text: String, nm: String, min_w := 460.0) -> Button:
	var b := Button.new()
	b.name = nm
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size = Vector2(min_w, 64)
	b.focus_mode = Control.FOCUS_ALL
	b.mouse_entered.connect(func() -> void:
		if b.is_inside_tree() and b.is_visible_in_tree() and not b.disabled:
			b.grab_focus())
	return b


## Link a list of controls into a wrapping vertical focus chain.
static func chain(controls: Array) -> void:
	var vis: Array = controls.filter(func(c: Control) -> bool: return c.visible)
	for i in vis.size():
		var c: Control = vis[i]
		var prev: Control = vis[(i - 1 + vis.size()) % vis.size()]
		var nxt: Control = vis[(i + 1) % vis.size()]
		c.focus_neighbor_top = c.get_path_to(prev)
		c.focus_neighbor_bottom = c.get_path_to(nxt)
		c.focus_previous = c.get_path_to(prev)
		c.focus_next = c.get_path_to(nxt)
