#include "global_hotkeys.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <vector>

using namespace godot;

namespace {

constexpr UINT WM_APP_REGISTER = WM_APP + 1;
constexpr UINT WM_APP_UNREGISTER_ALL = WM_APP + 2;
constexpr wchar_t WINDOW_CLASS[] = L"GodotVitureGlobalHotkeys";

struct RegisterRequest {
	int id;
	UINT modifiers;
	UINT vk;
	bool ok;
};

bool parse_combo(const String &p_combo, UINT &r_modifiers, UINT &r_vk) {
	PackedStringArray parts = p_combo.replace(" ", "").split("+", false);
	if (parts.is_empty()) {
		return false;
	}
	r_modifiers = 0;
	for (int i = 0; i < parts.size() - 1; i++) {
		String mod = parts[i].to_lower();
		if (mod == "ctrl" || mod == "control") {
			r_modifiers |= MOD_CONTROL;
		} else if (mod == "alt") {
			r_modifiers |= MOD_ALT;
		} else if (mod == "shift") {
			r_modifiers |= MOD_SHIFT;
		} else if (mod == "win" || mod == "super" || mod == "meta") {
			r_modifiers |= MOD_WIN;
		} else {
			return false;
		}
	}

	String key = parts[parts.size() - 1].to_upper();
	if (key.length() == 1 && ((key[0] >= 'A' && key[0] <= 'Z') || (key[0] >= '0' && key[0] <= '9'))) {
		r_vk = static_cast<UINT>(key[0]); // VK codes for letters and digits are their ASCII values.
		return true;
	}
	if (key.length() > 1 && key[0] == 'F' && key.substr(1).is_valid_int()) {
		int n = key.substr(1).to_int();
		if (n >= 1 && n <= 24) {
			r_vk = VK_F1 + n - 1;
			return true;
		}
		return false;
	}
	struct Named {
		const char *name;
		UINT vk;
	};
	static const Named named[] = {
		{ "SPACE", VK_SPACE }, { "ENTER", VK_RETURN }, { "TAB", VK_TAB }, { "ESCAPE", VK_ESCAPE },
		{ "UP", VK_UP }, { "DOWN", VK_DOWN }, { "LEFT", VK_LEFT }, { "RIGHT", VK_RIGHT },
		{ "PAGEUP", VK_PRIOR }, { "PAGEDOWN", VK_NEXT }, { "HOME", VK_HOME }, { "END", VK_END },
	};
	for (const Named &n : named) {
		if (key == n.name) {
			r_vk = n.vk;
			return true;
		}
	}
	return false;
}

} // namespace

namespace godot {

// Window procedure for the hidden message-only window; runs on the hotkey thread.
struct HotkeyWindow {
	static LRESULT CALLBACK proc(HWND p_hwnd, UINT p_msg, WPARAM p_wparam, LPARAM p_lparam) {
		// Ids registered by this thread; only touched on this thread.
		static thread_local std::vector<int> registered;
		auto *owner = reinterpret_cast<GlobalHotkeys *>(GetWindowLongPtrW(p_hwnd, GWLP_USERDATA));

		switch (p_msg) {
			case WM_HOTKEY:
				if (owner) {
					owner->call_deferred("_on_hotkey", static_cast<int>(p_wparam));
				}
				return 0;
			case WM_APP_REGISTER: {
				auto *req = reinterpret_cast<RegisterRequest *>(p_lparam);
				req->ok = RegisterHotKey(p_hwnd, req->id, req->modifiers, req->vk);
				if (req->ok) {
					registered.push_back(req->id);
				}
				return 0;
			}
			case WM_APP_UNREGISTER_ALL:
				for (int id : registered) {
					UnregisterHotKey(p_hwnd, id);
				}
				registered.clear();
				return 0;
			case WM_CLOSE:
				for (int id : registered) {
					UnregisterHotKey(p_hwnd, id);
				}
				registered.clear();
				DestroyWindow(p_hwnd);
				return 0;
			case WM_DESTROY:
				PostQuitMessage(0);
				return 0;
		}
		return DefWindowProcW(p_hwnd, p_msg, p_wparam, p_lparam);
	}
};

} // namespace godot

GlobalHotkeys::~GlobalHotkeys() {
	_exit_tree();
}

void GlobalHotkeys::_exit_tree() {
	if (thread.joinable()) {
		if (hwnd) {
			PostMessageW(static_cast<HWND>(hwnd), WM_CLOSE, 0, 0);
		}
		thread.join();
	}
	hwnd = nullptr;
	window_ready = false;
	started = false;
	names.clear();
}

bool GlobalHotkeys::ensure_thread() {
	if (started) {
		return hwnd != nullptr;
	}
	started = true;
	thread = std::thread(&GlobalHotkeys::run, this);
	std::unique_lock<std::mutex> lock(mutex);
	ready.wait(lock, [this] { return window_ready; });
	return hwnd != nullptr;
}

void GlobalHotkeys::run() {
	HINSTANCE instance = GetModuleHandleW(nullptr);
	WNDCLASSW wc = {};
	wc.lpfnWndProc = &HotkeyWindow::proc;
	wc.hInstance = instance;
	wc.lpszClassName = WINDOW_CLASS;
	RegisterClassW(&wc); // Fails harmlessly if already registered.

	HWND window = CreateWindowExW(0, WINDOW_CLASS, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, instance, nullptr);
	if (window) {
		SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
	}
	{
		std::lock_guard<std::mutex> lock(mutex);
		hwnd = window;
		window_ready = true;
	}
	ready.notify_all();
	if (!window) {
		return;
	}

	MSG msg;
	while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
		TranslateMessage(&msg);
		DispatchMessageW(&msg);
	}
}

bool GlobalHotkeys::register_hotkey(const String &p_name, const String &p_combo, bool p_repeat) {
	UINT modifiers = 0, vk = 0;
	if (!parse_combo(p_combo, modifiers, vk)) {
		UtilityFunctions::push_error("GlobalHotkeys: can't parse '", p_combo, "'.");
		return false;
	}
	if (!p_repeat) {
		modifiers |= MOD_NOREPEAT;
	}
	if (!ensure_thread()) {
		UtilityFunctions::push_error("GlobalHotkeys: failed to create the hotkey window.");
		return false;
	}

	names.push_back(p_name);
	RegisterRequest req = { static_cast<int>(names.size()), modifiers, vk, false };
	// SendMessage runs the registration on the hotkey thread and waits for it.
	SendMessageW(static_cast<HWND>(hwnd), WM_APP_REGISTER, 0, reinterpret_cast<LPARAM>(&req));
	if (!req.ok) {
		UtilityFunctions::push_warning("GlobalHotkeys: '", p_combo, "' is already in use by another application.");
	}
	return req.ok;
}

void GlobalHotkeys::unregister_all() {
	if (hwnd) {
		SendMessageW(static_cast<HWND>(hwnd), WM_APP_UNREGISTER_ALL, 0, 0);
	}
	names.clear();
}

void GlobalHotkeys::_on_hotkey(int p_id) {
	if (p_id >= 1 && p_id <= names.size()) {
		emit_signal("hotkey_pressed", names[p_id - 1]);
	}
}

void GlobalHotkeys::_bind_methods() {
	ClassDB::bind_method(D_METHOD("register_hotkey", "name", "combo", "repeat"), &GlobalHotkeys::register_hotkey, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("unregister_all"), &GlobalHotkeys::unregister_all);
	ClassDB::bind_method(D_METHOD("_on_hotkey", "id"), &GlobalHotkeys::_on_hotkey);

	ADD_SIGNAL(MethodInfo("hotkey_pressed", PropertyInfo(Variant::STRING, "name")));
}
