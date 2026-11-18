extends RefCounted
## Fighter look (materials + fighter-only rim lights), every number in one place.
##
## Why: the Meshy fighters read as dark flat blocks under the arena lights (dark skin sits darker than the crowd, SSAO fills the
## neck / shoulder / arm gaps, there is no rim light, the pale boxer is washed out and unshaded). The motion is unchanged; this only
## gives the body form.
##   * material: rim light, roughness, a per-skin albedo multiplier (lift for the dark skins, pull-down for boxer1);
##   * light: a pair of directional "form lights" that light ONLY meshes on FIGHTER_LAYER (light_cull_mask), so the crowd, ring and
##     floor are not brightened. They are world-fixed from two diagonal sides, so some edge of every fighter is rimmed from any camera
##     angle; the material rim is view dependent and covers the rest.
## Preload this script, don't reference it by class name.

const FIGHTER_LAYER := 1 << 19          ## render layer 20 (bit 19): fighter meshes live on layer 1 AND this one
const RIG_GROUP := &"fighter_form_lights"

## Per skin (the glb name in roster.gd "skin"): albedo multiplier (HDR ok), rim strength / tint, roughness scale (factor on the
## glb's roughness map, or the plain value where the glb has none).
## `unlit_fix`: boxer1 / boxer2 import with emission_enabled (white emission over the colour texture) and metallic 1.0, so they are
## self-lit and ignore every light (the flat, washed-out look, and why an albedo multiplier alone did nothing). Switch both off so the
## body takes shading.
const SKINS := {
	"viper_alt": {"albedo": 1.00, "rim": 0.60, "rim_tint": 0.40, "roughness": 0.68},
	"anvil": {"albedo": 1.30, "rim": 0.60, "rim_tint": 0.35, "roughness": 0.70},
	"oak": {"albedo": 1.08, "rim": 0.42, "rim_tint": 0.40, "roughness": 0.68},
	"boxer1": {"albedo": 0.88, "rim": 0.18, "rim_tint": 0.30, "roughness": 0.80, "unlit_fix": true},
	"boxer2": {"albedo": 1.40, "rim": 0.45, "rim_tint": 0.35, "roughness": 0.75, "unlit_fix": true},
}
const DEFAULT_SKIN := {"albedo": 1.0, "rim": 0.5, "rim_tint": 0.35, "roughness": 0.7}

## Form lights: two diagonal directional lights, cool and warm, no shadows, fighter layer only.
const FORM_LIGHTS := [
	{"yaw": 40.0, "pitch": -38.0, "color": Color(0.80, 0.88, 1.0), "energy": 0.50},
	{"yaw": 220.0, "pitch": -30.0, "color": Color(1.0, 0.90, 0.78), "energy": 0.35},
]


## `mat` is a per-fighter copy of the glb material; `tint` the corner tint already chosen by the fighter.
static func style_material(mat: StandardMaterial3D, skin_id: String, tint: Color) -> void:
	var p: Dictionary = SKINS.get(skin_id, DEFAULT_SKIN)
	var k: float = p["albedo"]
	mat.albedo_color = Color(tint.r * k, tint.g * k, tint.b * k, tint.a)
	mat.rim_enabled = true
	mat.rim = p["rim"]
	mat.rim_tint = p["rim_tint"]
	mat.roughness = p["roughness"]
	if p.get("unlit_fix", false):
		mat.emission_enabled = false
		mat.metallic = 0.0


## Put every mesh under `root` on the fighter layer (still on layer 1, so the normal arena lights keep lighting it).
static func tag_meshes(root: Node) -> void:
	for n in root.find_children("*", "MeshInstance3D", true, false):
		(n as MeshInstance3D).layers |= FIGHTER_LAYER


## One rig per scene: added to `parent` the first time a Meshy fighter needs it.
static func ensure_lights(parent) -> void:
	if parent == null or not is_instance_valid(parent) or not parent.is_inside_tree() or parent.get_tree().get_first_node_in_group(RIG_GROUP) != null:
		return
	var rig := Node3D.new()
	rig.name = "FighterFormLights"
	rig.add_to_group(RIG_GROUP)
	parent.add_child(rig)
	for d: Dictionary in FORM_LIGHTS:
		var l := DirectionalLight3D.new()
		l.light_color = d["color"]
		l.light_energy = d["energy"]
		l.light_cull_mask = FIGHTER_LAYER
		l.shadow_enabled = false
		l.light_volumetric_fog_energy = 0.0   # directional lights otherwise light the arena's volumetric fog (the whole backdrop)
		l.rotation = Vector3(deg_to_rad(d["pitch"]), deg_to_rad(d["yaw"]), 0.0)
		rig.add_child(l)
