#pragma once

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace godot {

// Captures a Windows monitor or a single window into a texture with Windows Graphics Capture,
// which (unlike DXGI Desktop Duplication) works when the monitor is driven by
// a different GPU than this process, as on hybrid-graphics laptops.
//
// Pixels arrive as BGRA and are uploaded unswizzled into an RGBA8 texture, so
// sample it as `.bgr` in a shader. The mouse cursor is part of the image.
class DesktopCapture : public RefCounted {
	GDCLASS(DesktopCapture, RefCounted)

public:
	~DesktopCapture();

	static PackedStringArray get_monitor_names();
	// Top-level app windows that can be captured: [{handle, title, process}].
	static Array get_windows();
	// The window the user is working in (0 if none, or if it belongs to us).
	static int64_t get_foreground_window();
	static Dictionary get_window_info(int64_t p_handle);

	bool start(int p_monitor);
	// Captures one window; follows it as it resizes, even when covered by
	// other windows (not while minimized).
	bool start_window(int64_t p_handle);
	void stop();
	bool is_capturing() const { return impl != nullptr; }
	String get_last_error() const { return last_error; }

	bool update();
	Ref<ImageTexture> get_texture() const { return texture; }
	Vector2i get_size() const { return size; }

protected:
	static void _bind_methods();

private:
	struct Impl; // Keeps WinRT headers out of this header.
	Impl *impl = nullptr;

	String last_error;
	Vector2i size;
	PackedByteArray pixels;
	Ref<Image> image;
	Ref<ImageTexture> texture;

	int64_t window = 0; // Captured window, or 0 when capturing a monitor.

	bool fail(const String &p_message);
	bool resize(int p_width, int p_height);
	bool begin(void *p_monitor, int64_t p_window, const String &p_name);
};

} // namespace godot
