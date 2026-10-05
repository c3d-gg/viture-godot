#pragma once

#include <godot_cpp/classes/node.hpp>

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <set>
#include <thread>

namespace godot {

// Creates virtual monitors through the SudoVDA driver (SudoMaker Virtual
// Display Adapter), so extra screens exist without physical displays.
//
// The driver removes every virtual monitor if it isn't pinged for a few
// seconds, so a background thread keeps it alive while this node is in the
// tree. Monitors are removed again on exit; after a crash the driver's
// watchdog cleans them up.
class VirtualDisplays : public Node {
	GDCLASS(VirtualDisplays, Node)

public:
	~VirtualDisplays();

	void _exit_tree() override;

	bool is_available();
	String get_last_error() const { return last_error; }

	// Adds (or finds, if it already exists) the virtual monitor for p_slot and
	// returns its Windows device name such as "\\.\DISPLAY7", or "" on failure.
	// Blocks for up to a few seconds while Windows brings the monitor up.
	String add_display(int p_slot, int p_width, int p_height, int p_refresh_rate);
	bool remove_display(int p_slot);
	void remove_all();

protected:
	static void _bind_methods();

private:
	void *device = nullptr;
	std::mutex io_mutex; // Serializes DeviceIoControl between threads.
	std::set<int> slots;
	String last_error;

	std::thread ping_thread;
	std::mutex ping_mutex;
	std::condition_variable ping_wake;
	bool ping_stop = false;
	unsigned ping_interval_ms = 1000;

	bool open();
	void close();
	bool ioctl(unsigned long p_code, const void *p_in, unsigned long p_in_size, void *p_out, unsigned long p_out_size);
	void start_pinging();
	void stop_pinging();
	bool fail(const String &p_message);
};

} // namespace godot
