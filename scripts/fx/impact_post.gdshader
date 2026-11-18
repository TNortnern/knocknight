shader_type canvas_item;
render_mode unshaded;
// Screen-space half of the web build's impact presentation:
//  - impact-blur.js: nine-tap same-frame smear (direction + roll + zoom terms, strength^0.8)
//  - screen-impact.js: rock edge vignette (max alpha .3), warm side vignette, contact flash, rock desaturation/dim
uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;

uniform float blur_strength = 0.0;
uniform vec2 blur_dir = vec2(1.0, 0.0);   // camera axes, +y up
uniform float blur_roll = 0.0;             // radians
uniform float blur_zoom = 0.0;             // legacy fov delta in degrees (42 - fov)
uniform float rock = 0.0;                  // 0..1 rocked-ness
uniform float warm_alpha = 0.0;
uniform float warm_side = 1.0;
uniform vec4 flash = vec4(0.5, 0.4, 0.05, 0.0); // xy = uv, z = radius (fraction of min side), w = alpha

vec3 frame_at(vec2 uv, vec2 res) {
	vec2 e = 0.5 / res;
	return texture(screen_tex, clamp(uv, e, vec2(1.0) - e)).rgb;
}

void fragment() {
	vec2 res = 1.0 / SCREEN_PIXEL_SIZE;
	vec2 uv = SCREEN_UV;
	vec3 col;
	if (blur_strength > 0.001) {
		vec2 pixels = vec2(uv.x - 0.5, 0.5 - uv.y) * res;   // y up, like the web shader
		float radius = 72.0 * res.y / 720.0;
		vec2 motion = blur_dir * radius;
		motion += vec2(-pixels.y, pixels.x) * blur_roll * 0.6;
		motion += pixels * (blur_zoom / 42.0) * 0.4;
		float max_motion = 128.0 * res.y / 720.0;
		motion *= min(1.0, max_motion / max(length(motion), 0.0001));
		vec2 off = motion / res * pow(blur_strength, 0.8);
		off.y = -off.y;
		col = frame_at(uv, res) * 0.28;
		col += (frame_at(uv - off * 0.25, res) + frame_at(uv + off * 0.25, res)) * 0.18;
		col += (frame_at(uv - off * 0.50, res) + frame_at(uv + off * 0.50, res)) * 0.10;
		col += (frame_at(uv - off * 0.75, res) + frame_at(uv + off * 0.75, res)) * 0.06;
		col += (frame_at(uv - off, res) + frame_at(uv + off, res)) * 0.02;
	} else {
		col = frame_at(uv, res);
	}
	// rock backdrop grade: saturate(1 - .14 r) brightness(1 - .04 r)
	float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
	col = mix(vec3(luma), col, 1.0 - 0.14 * rock) * (1.0 - 0.04 * rock);

	vec2 px = uv * res;
	float mn = min(res.x, res.y);
	// warm vignette on the victim's side
	if (warm_alpha > 0.002) {
		float g = warm_side > 0.0 ? (res.x - px.x) / (res.x * 0.58) : px.x / (res.x * 0.58);
		g = clamp(g, 0.0, 1.0);
		float a = g < 0.48 ? mix(warm_alpha, warm_alpha * 0.38, g / 0.48) : mix(warm_alpha * 0.38, 0.0, (g - 0.48) / 0.52);
		vec3 wc = mix(vec3(1.0, 0.486, 0.243), vec3(1.0, 0.4, 0.204), clamp(g / 0.48, 0.0, 1.0));
		col = mix(col, wc, a);
	}
	// rock edge vignette (inner stop fully transparent)
	float ea = clamp(rock * 0.3, 0.0, 0.3);
	if (ea > 0.002) {
		vec2 c = vec2(res.x * 0.5, res.y * 0.52);
		float r0 = mn * 0.26;
		float r1 = max(res.x, res.y) * 0.72;
		float t = clamp((length(px - c) - r0) / (r1 - r0), 0.0, 1.0);
		float a = t < 0.52 ? 0.0 : (t < 0.78 ? mix(0.0, ea * 0.42, (t - 0.52) / 0.26) : mix(ea * 0.42, ea, (t - 0.78) / 0.22));
		col = mix(col, vec3(0.016, 0.027, 0.047), a);
	}
	// contact flash
	if (flash.w > 0.003) {
		float rad = max(flash.z * mn, 1.0);
		float d = length(px - flash.xy * res) / rad;
		float g = clamp(1.0 - d, 0.0, 1.0);
		float local = min(flash.w * 1.12, 0.56);
		vec3 fc = mix(vec3(1.0, 0.455, 0.235), vec3(1.0, 0.933, 0.792), smoothstep(0.0, 1.0, g * g));
		col = mix(col, fc, local * g * (0.35 + 0.65 * g));
	}
	COLOR = vec4(col, 1.0);
}
