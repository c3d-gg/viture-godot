#include "cursor_fence.h"

#include <godot_cpp/core/class_db.hpp>

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <timeapi.h>

using namespace godot;

namespace {

int64_t pack(int32_t p_a, int32_t p_b) {
	return (static_cast<int64_t>(p_a) << 32) | static_cast<uint32_t>(p_b);
}

int32_t high(int64_t p_v) {
	return static_cast<int32_t>(p_v >> 32);
}

int32_t low(int64_t p_v) {
	return static_cast<int32_t>(p_v & 0xffffffff);
}

} // namespace

CursorFence::~CursorFence() {
	_exit_tree();
}

void CursorFence::_enter_tree() {
	if (running.exchange(true)) {
		return;
	}
	thread = std::thread(&CursorFence::run, this);
}

void CursorFence::_exit_tree() {
	running = false;
	if (thread.joinable()) {
		thread.join();
	}
}

void CursorFence::set_fence(const Rect2i &p_rect) {
	fence_xy = pack(p_rect.position.x, p_rect.position.y);
	fence_size = pack(p_rect.size.x, p_rect.size.y);
}

Rect2i CursorFence::get_fence() const {
	int64_t xy = fence_xy, size = fence_size;
	return Rect2i(high(xy), low(xy), high(size), low(size));
}

void CursorFence::run() {
	timeBeginPeriod(1); // Poll at ~250 Hz rather than the default 64 Hz tick.
	POINT last_outside = {};
	bool have_outside = false;
	while (running) {
		Rect2i fence = get_fence();
		POINT p;
		if (fence.size.x > 0 && fence.size.y > 0 && GetCursorPos(&p)) {
			bool inside = p.x >= fence.position.x && p.x < fence.position.x + fence.size.x &&
					p.y >= fence.position.y && p.y < fence.position.y + fence.size.y;
			if (!inside) {
				last_outside = p;
				have_outside = true;
			} else if (have_outside) {
				SetCursorPos(last_outside.x, last_outside.y);
			} else {
				// Started inside: send it to the middle of the primary monitor.
				SetCursorPos(GetSystemMetrics(SM_CXSCREEN) / 2, GetSystemMetrics(SM_CYSCREEN) / 2);
			}
		}
		Sleep(4);
	}
	timeEndPeriod(1);
}

void CursorFence::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_fence", "rect"), &CursorFence::set_fence);
	ClassDB::bind_method(D_METHOD("get_fence"), &CursorFence::get_fence);
	ADD_PROPERTY(PropertyInfo(Variant::RECT2I, "fence"), "set_fence", "get_fence");
}
