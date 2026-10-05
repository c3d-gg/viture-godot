#pragma once

#include <cstdint> // viture_device.h uses uint8_t/uint64_t without including it.

#include <viture_device.h>
#include <viture_device_carina.h>
#include <viture_glasses_provider.h>
#include <viture_protocol_public.h>
#include <viture_version.h>

#include <string>
#include <vector>

// Runtime binding to the VITURE Glasses SDK (glasses.dll).
//
// The SDK is loaded with LoadLibrary instead of being linked against
// glasses.lib, so Godot can always load the extension and report a readable
// error when the (non-redistributable) SDK files are missing. Function pointer
// types come straight from the SDK headers via decltype.
namespace viture {

using Handle = XRDeviceProviderHandle;

constexpr uint16_t VENDOR_ID = 0x35CA;

#define VITURE_FN(name) decltype(&::xr_device_provider_##name) name = nullptr

struct Api {
	VITURE_FN(create);
	VITURE_FN(initialize);
	VITURE_FN(start);
	VITURE_FN(stop);
	VITURE_FN(shutdown);
	VITURE_FN(destroy);
	VITURE_FN(get_device_type);
	VITURE_FN(is_product_id_valid);
	VITURE_FN(is_product_support_imu_frequency);
	VITURE_FN(get_market_name);
	VITURE_FN(register_state_callback);
	VITURE_FN(set_log_level);

	VITURE_FN(get_display_mode);
	VITURE_FN(set_display_mode);
	VITURE_FN(switch_dimension);
	VITURE_FN(get_brightness_level);
	VITURE_FN(set_brightness_level);

	// Gen1 / Gen2: IMU pose pushed from an SDK thread.
	VITURE_FN(register_imu_pose_callback);
	VITURE_FN(open_imu);
	VITURE_FN(close_imu);

	// Carina (Luma Ultra): pose polled from host-side VIO.
	VITURE_FN(set_dof_type_carina);
	VITURE_FN(get_gl_pose_carina);
	VITURE_FN(reset_pose_carina);

	decltype(&::GetVersionString) get_version_string = nullptr;

	bool load(const std::string &path, std::string &r_error);
	bool is_loaded() const { return module != nullptr; }

private:
	void *module = nullptr;
};

#undef VITURE_FN

// Product IDs of every connected USB device with the VITURE vendor ID.
std::vector<int> find_connected_product_ids();

// Applies the Windows "Extend" display topology; returns a Win32 error code.
long extend_desktop();

} // namespace viture
