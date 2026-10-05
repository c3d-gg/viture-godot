shader_type spatial;
render_mode unshaded, cull_disabled;

// DesktopCapture uploads BGRA bytes into an RGBA texture; swap back here.
// The capture has no mipmaps (it changes every frame), so filtering is done
// by hand: supersample when the screen is shown smaller than its pixels
// (otherwise text shimmers), bicubic when larger (otherwise it blurs).
uniform sampler2D screen : source_color, filter_linear, repeat_disable;
// Extra crispness on top: 0 = none, 1 = strong.
uniform float sharpness : hint_range(0.0, 1.0) = 0.3;

vec3 tap(vec2 uv) {
	return textureLod(screen, uv, 0.0).bgr;
}

// Catmull-Rom bicubic in 9 bilinear taps.
vec3 bicubic(vec2 uv, vec2 size) {
	vec2 pos = uv * size;
	vec2 centre = floor(pos - 0.5) + 0.5;
	vec2 f = pos - centre;
	vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
	vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
	vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
	vec2 w3 = f * f * (-0.5 + 0.5 * f);
	vec2 w12 = w1 + w2;
	vec2 t0 = (centre - 1.0) / size;
	vec2 t12 = (centre + w2 / w12) / size;
	vec2 t3 = (centre + 2.0) / size;
	vec3 c = tap(vec2(t0.x, t0.y)) * w0.x * w0.y
			+ tap(vec2(t12.x, t0.y)) * w12.x * w0.y
			+ tap(vec2(t3.x, t0.y)) * w3.x * w0.y
			+ tap(vec2(t0.x, t12.y)) * w0.x * w12.y
			+ tap(vec2(t12.x, t12.y)) * w12.x * w12.y
			+ tap(vec2(t3.x, t12.y)) * w3.x * w12.y
			+ tap(vec2(t0.x, t3.y)) * w0.x * w3.y
			+ tap(vec2(t12.x, t3.y)) * w12.x * w3.y
			+ tap(vec2(t3.x, t3.y)) * w3.x * w3.y;
	return max(c, 0.0);
}

void fragment() {
	vec2 size = vec2(textureSize(screen, 0));
	// How far one screen pixel reaches across the texture (computed up front:
	// derivatives aren't reliable inside branches).
	vec2 du = dFdx(UV);
	vec2 dv = dFdy(UV);
	float texels_per_pixel = max(length(du * size), length(dv * size));

	vec3 color;
	if (texels_per_pixel > 1.0) {
		// Shown smaller than 1:1: average an n x n grid over this pixel's footprint.
		int n = int(clamp(ceil(texels_per_pixel), 2.0, 4.0));
		color = vec3(0.0);
		for (int i = 0; i < n; i++) {
			for (int j = 0; j < n; j++) {
				vec2 o = (vec2(float(i), float(j)) + 0.5) / float(n) - 0.5;
				color += tap(UV + o.x * du + o.y * dv);
			}
		}
		color /= float(n * n);
	} else {
		color = bicubic(UV, size);
	}

	if (sharpness > 0.0) {
		// Unsharp mask over one screen pixel (or one texel, whichever is larger).
		vec2 step = max(abs(du) + abs(dv), 1.0 / size);
		vec3 blur = (tap(UV + vec2(step.x, 0.0)) + tap(UV - vec2(step.x, 0.0))
				+ tap(UV + vec2(0.0, step.y)) + tap(UV - vec2(0.0, step.y))) * 0.25;
		color = max(color + sharpness * (color - blur), 0.0);
	}
	ALBEDO = color;
}
