#pragma once

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

#include <condition_variable>
#include <mutex>
#include <thread>

namespace godot {

// System-wide hotkeys that fire even while another application has focus.
//
// Uses Win32 RegisterHotKey on a hidden message-only window owned by a
// background thread (hotkeys belong to the thread that registers them), and
// emits `hotkey_pressed` on the main thread.
class GlobalHotkeys : public Node {
	GDCLASS(GlobalHotkeys, Node)

public:
	~GlobalHotkeys();

	void _exit_tree() override;

	// p_combo is e.g. "Ctrl+Alt+Shift+Space": modifiers Ctrl, Alt, Shift, Win
	// plus one key (A-Z, 0-9, F1-F24, Space, Enter, Tab, Escape, Up, Down,
	// Left, Right, PageUp, PageDown, Home, End). Returns false if the combo is
	// invalid or already taken by another application.
	bool register_hotkey(const String &p_name, const String &p_combo, bool p_repeat = false);
	void unregister_all();

protected:
	static void _bind_methods();

private:
	std::thread thread;
	void *hwnd = nullptr;
	std::mutex mutex;
	std::condition_variable ready;
	bool window_ready = false; // Set by the thread once hwnd is final (possibly null).
	bool started = false;
	PackedStringArray names; // Hotkey id - 1 -> name.

	bool ensure_thread();
	void run();
	void _on_hotkey(int p_id);

	friend struct HotkeyWindow;
};

} // namespace godot
