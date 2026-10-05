#pragma once

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/rect2i.hpp>

#include <atomic>
#include <thread>

namespace godot {

// Keeps the mouse cursor out of a desktop rectangle (e.g. the glasses' own
// display, which only shows the virtual screens and isn't somewhere to work).
//
// Windows doesn't allow gaps between monitors, so instead a background thread
// polls the cursor and puts it back where it was whenever it enters the fence.
// Active while this node is in the tree and the fence is non-empty.
class CursorFence : public Node {
	GDCLASS(CursorFence, Node)

public:
	~CursorFence();

	void _enter_tree() override;
	void _exit_tree() override;

	void set_fence(const Rect2i &p_rect);
	Rect2i get_fence() const;

protected:
	static void _bind_methods();

private:
	// Packed so the polling thread reads a consistent rect without locking.
	std::atomic<int64_t> fence_xy{ 0 };
	std::atomic<int64_t> fence_size{ 0 };
	std::atomic<bool> running{ false };
	std::thread thread;

	void run();
};

} // namespace godot
