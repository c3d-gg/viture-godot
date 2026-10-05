shader_type spatial;
render_mode unshaded, cull_disabled;

// DesktopCapture uploads BGRA bytes into an RGBA texture; swap back here.
uniform sampler2D screen : source_color, filter_linear;

void fragment() {
	ALBEDO = texture(screen, UV).bgr;
}
