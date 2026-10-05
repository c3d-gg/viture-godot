#include "virtual_displays.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <setupapi.h>
#include <winioctl.h>

#include <chrono>
#include <cstdint>
#include <string>
#include <vector>

using namespace godot;

namespace {

// SudoVDA control interface, from SudoMaker/SudoVDA
// Common/Include/sudovda-ioctl.h (MIT / CC0, "choose the least restrictive").
namespace sudovda {

constexpr DWORD IOCTL_ADD_VIRTUAL_DISPLAY = CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS);
constexpr DWORD IOCTL_REMOVE_VIRTUAL_DISPLAY = CTL_CODE(FILE_DEVICE_UNKNOWN, 0x801, METHOD_BUFFERED, FILE_ANY_ACCESS);
constexpr DWORD IOCTL_GET_WATCHDOG = CTL_CODE(FILE_DEVICE_UNKNOWN, 0x803, METHOD_BUFFERED, FILE_ANY_ACCESS);
constexpr DWORD IOCTL_DRIVER_PING = CTL_CODE(FILE_DEVICE_UNKNOWN, 0x888, METHOD_BUFFERED, FILE_ANY_ACCESS);
constexpr DWORD IOCTL_GET_PROTOCOL_VERSION = CTL_CODE(FILE_DEVICE_UNKNOWN, 0x8FF, METHOD_BUFFERED, FILE_ANY_ACCESS);

// {e5bcc234-1e0c-418a-a0d4-ef8b7501414d}
constexpr GUID INTERFACE_GUID = { 0xe5bcc234, 0x1e0c, 0x418a, { 0xa0, 0xd4, 0xef, 0x8b, 0x75, 0x01, 0x41, 0x4d } };

struct ProtocolVersion {
	uint8_t major;
	uint8_t minor;
	uint8_t incremental;
	bool test_build;
};

struct AddParams {
	UINT width;
	UINT height;
	UINT refresh_rate; // Hz if < 1000, else mHz.
	GUID monitor_guid;
	CHAR device_name[14];
	CHAR serial_number[14];
};

struct RemoveParams {
	GUID monitor_guid;
};

struct AddOut {
	LUID adapter_luid;
	UINT target_id;
};

struct WatchdogOut {
	UINT timeout; // Seconds; 0 = disabled.
	UINT countdown;
};

} // namespace sudovda

// One fixed GUID per slot, so re-adding a slot finds the existing monitor.
GUID slot_guid(int p_slot) {
	// {5e1c7a90-3b6d-4f2a-8c1e-56495455520N}, "VITURE" in the node bytes.
	GUID guid = { 0x5e1c7a90, 0x3b6d, 0x4f2a, { 0x8c, 0x1e, 0x56, 0x49, 0x54, 0x55, 0x52, 0x00 } };
	guid.Data4[7] = static_cast<unsigned char>(p_slot);
	return guid;
}

// The GDI device name ("\\.\DISPLAYn") of the active path for a monitor, or "".
std::wstring find_display_name(const LUID &p_adapter, UINT p_target) {
	UINT32 path_count = 0, mode_count = 0;
	if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &path_count, &mode_count) != ERROR_SUCCESS) {
		return L"";
	}
	std::vector<DISPLAYCONFIG_PATH_INFO> paths(path_count);
	std::vector<DISPLAYCONFIG_MODE_INFO> modes(mode_count);
	if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &path_count, paths.data(), &mode_count, modes.data(), nullptr) != ERROR_SUCCESS) {
		return L"";
	}
	for (UINT32 i = 0; i < path_count; i++) {
		const DISPLAYCONFIG_PATH_INFO &path = paths[i];
		if (path.targetInfo.id != p_target || path.targetInfo.adapterId.LowPart != p_adapter.LowPart ||
				path.targetInfo.adapterId.HighPart != p_adapter.HighPart) {
			continue;
		}
		DISPLAYCONFIG_SOURCE_DEVICE_NAME source = {};
		source.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
		source.header.size = sizeof(source);
		source.header.adapterId = path.sourceInfo.adapterId;
		source.header.id = path.sourceInfo.id;
		if (DisplayConfigGetDeviceInfo(&source.header) == ERROR_SUCCESS) {
			return source.viewGdiDeviceName;
		}
	}
	return L"";
}

struct ActiveConfig {
	std::vector<DISPLAYCONFIG_PATH_INFO> paths;
	std::vector<DISPLAYCONFIG_MODE_INFO> modes;
};

bool query_active_config(ActiveConfig &r_config) {
	UINT32 path_count = 0, mode_count = 0;
	if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &path_count, &mode_count) != ERROR_SUCCESS) {
		return false;
	}
	r_config.paths.resize(path_count);
	r_config.modes.resize(mode_count);
	if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &path_count, r_config.paths.data(), &mode_count, r_config.modes.data(), nullptr) != ERROR_SUCCESS) {
		return false;
	}
	r_config.paths.resize(path_count);
	r_config.modes.resize(mode_count);
	return true;
}

String source_device_name(const DISPLAYCONFIG_PATH_INFO &p_path) {
	DISPLAYCONFIG_SOURCE_DEVICE_NAME source = {};
	source.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
	source.header.size = sizeof(source);
	source.header.adapterId = p_path.sourceInfo.adapterId;
	source.header.id = p_path.sourceInfo.id;
	if (DisplayConfigGetDeviceInfo(&source.header) != ERROR_SUCCESS) {
		return String();
	}
	return String(source.viewGdiDeviceName);
}

} // namespace

Dictionary VirtualDisplays::get_display_positions() {
	Dictionary result;
	ActiveConfig config;
	if (!query_active_config(config)) {
		return result;
	}
	for (const DISPLAYCONFIG_PATH_INFO &path : config.paths) {
		UINT32 index = path.sourceInfo.modeInfoIdx;
		if (index == DISPLAYCONFIG_PATH_MODE_IDX_INVALID || index >= config.modes.size()) {
			continue;
		}
		const POINTL &pos = config.modes[index].sourceMode.position;
		result[source_device_name(path)] = Vector2i(pos.x, pos.y);
	}
	return result;
}

bool VirtualDisplays::arrange_displays(const Dictionary &p_positions) {
	ActiveConfig config;
	if (!query_active_config(config)) {
		UtilityFunctions::push_error("VirtualDisplays: QueryDisplayConfig failed.");
		return false;
	}
	bool changed = false;
	for (const DISPLAYCONFIG_PATH_INFO &path : config.paths) {
		UINT32 index = path.sourceInfo.modeInfoIdx;
		if (index == DISPLAYCONFIG_PATH_MODE_IDX_INVALID || index >= config.modes.size()) {
			continue;
		}
		String name = source_device_name(path);
		if (!p_positions.has(name)) {
			continue;
		}
		Vector2i target = p_positions[name];
		POINTL &pos = config.modes[index].sourceMode.position;
		if (pos.x != target.x || pos.y != target.y) {
			pos.x = target.x;
			pos.y = target.y;
			changed = true;
		}
	}
	if (!changed) {
		return true;
	}
	// Exactly as asked first; if Windows rejects the layout, let it adjust.
	LONG result = SetDisplayConfig(static_cast<UINT32>(config.paths.size()), config.paths.data(),
			static_cast<UINT32>(config.modes.size()), config.modes.data(),
			SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_SAVE_TO_DATABASE);
	if (result != ERROR_SUCCESS) {
		UtilityFunctions::print("VirtualDisplays: exact layout rejected (", static_cast<int64_t>(result), "); letting Windows adjust it.");
		result = SetDisplayConfig(static_cast<UINT32>(config.paths.size()), config.paths.data(),
				static_cast<UINT32>(config.modes.size()), config.modes.data(),
				SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_SAVE_TO_DATABASE | SDC_ALLOW_CHANGES);
	}
	if (result != ERROR_SUCCESS) {
		UtilityFunctions::push_error("VirtualDisplays: SetDisplayConfig failed (", static_cast<int64_t>(result), ").");
		return false;
	}
	return true;
}

VirtualDisplays::~VirtualDisplays() {
	_exit_tree();
}

void VirtualDisplays::_exit_tree() {
	remove_all();
	stop_pinging();
	close();
}

bool VirtualDisplays::fail(const String &p_message) {
	last_error = p_message;
	UtilityFunctions::push_error("VirtualDisplays: ", p_message);
	return false;
}

bool VirtualDisplays::is_available() {
	return open();
}

bool VirtualDisplays::open() {
	if (device) {
		return true;
	}
	HDEVINFO info = SetupDiGetClassDevsW(&sudovda::INTERFACE_GUID, nullptr, nullptr, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
	if (info == INVALID_HANDLE_VALUE) {
		return fail("SudoVDA driver not found (is the SudoMaker Virtual Display Adapter installed?).");
	}
	SP_DEVICE_INTERFACE_DATA iface = {};
	iface.cbSize = sizeof(iface);
	std::wstring path;
	if (SetupDiEnumDeviceInterfaces(info, nullptr, &sudovda::INTERFACE_GUID, 0, &iface)) {
		DWORD size = 0;
		SetupDiGetDeviceInterfaceDetailW(info, &iface, nullptr, 0, &size, nullptr);
		std::vector<uint8_t> buffer(size);
		auto *detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W *>(buffer.data());
		detail->cbSize = sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W);
		if (SetupDiGetDeviceInterfaceDetailW(info, &iface, detail, size, nullptr, nullptr)) {
			path = detail->DevicePath;
		}
	}
	SetupDiDestroyDeviceInfoList(info);
	if (path.empty()) {
		return fail("SudoVDA driver not found (is the SudoMaker Virtual Display Adapter installed?).");
	}

	HANDLE handle = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
			nullptr, OPEN_EXISTING, 0, nullptr);
	if (handle == INVALID_HANDLE_VALUE) {
		return fail(vformat("can't open the SudoVDA driver (Win32 error %d).", static_cast<int>(GetLastError())));
	}
	device = handle;

	sudovda::ProtocolVersion version = {};
	if (!ioctl(sudovda::IOCTL_GET_PROTOCOL_VERSION, nullptr, 0, &version, sizeof(version)) ||
			version.major != 0 || version.minor < 2) {
		close();
		return fail(vformat("unsupported SudoVDA protocol %d.%d (need 0.2+).", version.major, version.minor));
	}

	sudovda::WatchdogOut watchdog = {};
	if (ioctl(sudovda::IOCTL_GET_WATCHDOG, nullptr, 0, &watchdog, sizeof(watchdog)) && watchdog.timeout > 0) {
		ping_interval_ms = watchdog.timeout * 1000 / 3;
	}
	start_pinging();
	last_error = String();
	return true;
}

void VirtualDisplays::close() {
	if (device) {
		CloseHandle(static_cast<HANDLE>(device));
		device = nullptr;
	}
}

bool VirtualDisplays::ioctl(unsigned long p_code, const void *p_in, unsigned long p_in_size, void *p_out, unsigned long p_out_size) {
	std::lock_guard<std::mutex> lock(io_mutex);
	if (!device) {
		return false;
	}
	DWORD returned = 0;
	return DeviceIoControl(static_cast<HANDLE>(device), p_code, const_cast<void *>(p_in), p_in_size, p_out, p_out_size, &returned, nullptr);
}

void VirtualDisplays::start_pinging() {
	if (ping_thread.joinable()) {
		return;
	}
	ping_stop = false;
	ping_thread = std::thread([this] {
		std::unique_lock<std::mutex> lock(ping_mutex);
		while (!ping_wake.wait_for(lock, std::chrono::milliseconds(ping_interval_ms), [this] { return ping_stop; })) {
			ioctl(sudovda::IOCTL_DRIVER_PING, nullptr, 0, nullptr, 0);
		}
	});
}

void VirtualDisplays::stop_pinging() {
	if (!ping_thread.joinable()) {
		return;
	}
	{
		std::lock_guard<std::mutex> lock(ping_mutex);
		ping_stop = true;
	}
	ping_wake.notify_all();
	ping_thread.join();
}

String VirtualDisplays::add_display(int p_slot, int p_width, int p_height, int p_refresh_rate) {
	ERR_FAIL_COND_V(p_slot < 0 || p_slot > 255, String());
	if (!open()) {
		return String();
	}

	sudovda::AddParams params = {};
	params.width = p_width;
	params.height = p_height;
	params.refresh_rate = p_refresh_rate;
	params.monitor_guid = slot_guid(p_slot);
	snprintf(params.device_name, sizeof(params.device_name), "VITURE VS %d", p_slot + 1);
	snprintf(params.serial_number, sizeof(params.serial_number), "VVS%04d", p_slot);

	sudovda::AddOut out = {};
	if (!ioctl(sudovda::IOCTL_ADD_VIRTUAL_DISPLAY, &params, sizeof(params), &out, sizeof(out))) {
		fail(vformat("adding a %dx%d@%d virtual display failed (Win32 error %d).", p_width, p_height, p_refresh_rate,
				static_cast<int>(GetLastError())));
		return String();
	}
	slots.insert(p_slot);

	// Windows takes a moment to bring the monitor up. If it doesn't join the
	// desktop by itself, apply Extend (as Win+P would) and keep waiting.
	bool extended = false;
	auto start = std::chrono::steady_clock::now();
	for (int delay = 20;; delay = std::min(delay * 2, 320)) {
		std::wstring name = find_display_name(out.adapter_luid, out.target_id);
		if (!name.empty()) {
			return String(name.c_str());
		}
		auto elapsed = std::chrono::steady_clock::now() - start;
		if (!extended && elapsed > std::chrono::milliseconds(2000)) {
			SetDisplayConfig(0, nullptr, 0, nullptr, SDC_APPLY | SDC_TOPOLOGY_EXTEND);
			extended = true;
		}
		if (elapsed > std::chrono::milliseconds(5000)) {
			break;
		}
		Sleep(delay);
	}
	fail(vformat("virtual display %d was added but never appeared on the desktop.", p_slot));
	return String();
}

bool VirtualDisplays::remove_display(int p_slot) {
	if (!device || slots.find(p_slot) == slots.end()) {
		return false;
	}
	sudovda::RemoveParams params = { slot_guid(p_slot) };
	slots.erase(p_slot);
	return ioctl(sudovda::IOCTL_REMOVE_VIRTUAL_DISPLAY, &params, sizeof(params), nullptr, 0);
}

void VirtualDisplays::remove_all() {
	std::set<int> to_remove = slots;
	for (int slot : to_remove) {
		remove_display(slot);
	}
}

void VirtualDisplays::_bind_methods() {
	ClassDB::bind_method(D_METHOD("is_available"), &VirtualDisplays::is_available);
	ClassDB::bind_method(D_METHOD("get_last_error"), &VirtualDisplays::get_last_error);
	ClassDB::bind_method(D_METHOD("add_display", "slot", "width", "height", "refresh_rate"), &VirtualDisplays::add_display);
	ClassDB::bind_method(D_METHOD("remove_display", "slot"), &VirtualDisplays::remove_display);
	ClassDB::bind_method(D_METHOD("remove_all"), &VirtualDisplays::remove_all);
	ClassDB::bind_static_method("VirtualDisplays", D_METHOD("arrange_displays", "positions"), &VirtualDisplays::arrange_displays);
	ClassDB::bind_static_method("VirtualDisplays", D_METHOD("get_display_positions"), &VirtualDisplays::get_display_positions);
}
