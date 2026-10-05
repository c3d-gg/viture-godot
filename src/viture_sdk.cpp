#include "viture_sdk.h"

#include <cstdio>

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <setupapi.h>

namespace viture {

static std::wstring to_wide(const std::string &s) {
	int len = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
	std::wstring w(len > 0 ? len - 1 : 0, L'\0');
	MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, w.data(), len);
	for (wchar_t &c : w) {
		if (c == L'/') {
			c = L'\\';
		}
	}
	return w;
}

bool Api::load(const std::string &path, std::string &r_error) {
	if (module) {
		return true;
	}

	// glasses.dll loads carina_vio.dll at runtime, whose own imports (OpenCV,
	// libusb, glew) are resolved through the process DLL search path. Put the
	// SDK folder on it for both the legacy and the SetDefaultDllDirectories modes.
	std::wstring wpath = to_wide(path);
	std::wstring dir = wpath.substr(0, wpath.find_last_of(L'\\'));
	SetDllDirectoryW(dir.c_str());
	AddDllDirectory(dir.c_str());

	HMODULE lib = LoadLibraryExW(wpath.c_str(), nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
	if (!lib) {
		r_error = "LoadLibrary failed for '" + path + "' (Win32 error " + std::to_string(GetLastError()) + ")";
		return false;
	}

	std::string missing;
	auto bind = [&](auto &r_fn, const char *name, bool required) {
		r_fn = reinterpret_cast<std::remove_reference_t<decltype(r_fn)>>(GetProcAddress(lib, name));
		if (!r_fn && required) {
			missing += std::string(" ") + name;
		}
	};

	bind(create, "xr_device_provider_create", true);
	bind(initialize, "xr_device_provider_initialize", true);
	bind(start, "xr_device_provider_start", true);
	bind(stop, "xr_device_provider_stop", true);
	bind(shutdown, "xr_device_provider_shutdown", true);
	bind(destroy, "xr_device_provider_destroy", true);
	bind(get_device_type, "xr_device_provider_get_device_type", true);
	bind(is_product_id_valid, "xr_device_provider_is_product_id_valid", true);
	bind(is_product_support_imu_frequency, "xr_device_provider_is_product_support_imu_frequency", false);
	bind(get_market_name, "xr_device_provider_get_market_name", false);
	bind(register_state_callback, "xr_device_provider_register_state_callback", false);
	bind(set_log_level, "xr_device_provider_set_log_level", false);

	bind(get_display_mode, "xr_device_provider_get_display_mode", false);
	bind(set_display_mode, "xr_device_provider_set_display_mode", false);
	bind(switch_dimension, "xr_device_provider_switch_dimension", false);
	bind(get_brightness_level, "xr_device_provider_get_brightness_level", false);
	bind(set_brightness_level, "xr_device_provider_set_brightness_level", false);

	bind(register_imu_pose_callback, "xr_device_provider_register_imu_pose_callback", false);
	bind(open_imu, "xr_device_provider_open_imu", false);
	bind(close_imu, "xr_device_provider_close_imu", false);

	bind(set_dof_type_carina, "xr_device_provider_set_dof_type_carina", false);
	bind(get_gl_pose_carina, "xr_device_provider_get_gl_pose_carina", false);
	bind(reset_pose_carina, "xr_device_provider_reset_pose_carina", false);

	bind(get_version_string, "GetVersionString", false);

	if (!missing.empty()) {
		r_error = "'" + path + "' is missing required SDK exports:" + missing;
		FreeLibrary(lib);
		return false;
	}
	module = lib;
	return true;
}

std::vector<int> find_connected_product_ids() {
	std::vector<int> ids;
	HDEVINFO devs = SetupDiGetClassDevsA(nullptr, "USB", nullptr, DIGCF_ALLCLASSES | DIGCF_PRESENT);
	if (devs == INVALID_HANDLE_VALUE) {
		return ids;
	}
	SP_DEVINFO_DATA info = {};
	info.cbSize = sizeof(info);
	for (DWORD i = 0; SetupDiEnumDeviceInfo(devs, i, &info); i++) {
		char instance_id[512];
		if (!SetupDiGetDeviceInstanceIdA(devs, &info, instance_id, sizeof(instance_id), nullptr)) {
			continue;
		}
		// Instance IDs look like "USB\VID_35CA&PID_1104\...". Skip per-interface
		// children ("&MI_xx") so each physical device is reported once.
		unsigned int vid = 0, pid = 0;
		char next = 0;
		if (sscanf_s(instance_id, "USB\\VID_%4x&PID_%4x%c", &vid, &pid, &next, 1) == 3 && vid == VENDOR_ID && next == '\\') {
			ids.push_back(static_cast<int>(pid));
		}
	}
	SetupDiDestroyDeviceInfoList(devs);
	return ids;
}

long extend_desktop() {
	return SetDisplayConfig(0, nullptr, 0, nullptr, SDC_APPLY | SDC_TOPOLOGY_EXTEND);
}

std::wstring find_glasses_display() {
	DISPLAY_DEVICEW adapter = {};
	adapter.cb = sizeof(adapter);
	for (DWORD i = 0; EnumDisplayDevicesW(nullptr, i, &adapter, 0); i++) {
		if (adapter.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) {
			DISPLAY_DEVICEW monitor = {};
			monitor.cb = sizeof(monitor);
			for (DWORD j = 0; EnumDisplayDevicesW(adapter.DeviceName, j, &monitor, 0); j++) {
				// DeviceID looks like "MONITOR\CVT3133\{...}"; CVT is VITURE's EDID vendor code.
				if (wcsstr(monitor.DeviceID, L"\\CVT")) {
					return adapter.DeviceName;
				}
			}
		}
		adapter.cb = sizeof(adapter);
	}
	return L"";
}

} // namespace viture
