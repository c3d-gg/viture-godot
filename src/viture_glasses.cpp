#include "viture_glasses.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <godot_cpp/classes/xr_server.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

viture::Api VitureGlasses::api;
VitureGlasses *VitureGlasses::active_instance = nullptr;

VitureGlasses::VitureGlasses() {
	// Created up front so stereo settings can be tuned before stereo is enabled.
	xr_interface.instantiate();
}

VitureGlasses::~VitureGlasses() {
	stop();
}

void VitureGlasses::_ready() {
	if (Engine::get_singleton()->is_editor_hint()) {
		set_process(false);
		return;
	}
	if (auto_start) {
		start();
	}
}

void VitureGlasses::_process(double p_delta) {
	if (!running) {
		return;
	}
	update_pose();

	if (!target.is_empty()) {
		Node3D *node = Object::cast_to<Node3D>(get_node_or_null(target));
		if (node) {
			node->set_transform(pose);
		}
	}
}

void VitureGlasses::_exit_tree() {
	stop();
}

bool VitureGlasses::fail(const String &p_message) {
	last_error = p_message;
	UtilityFunctions::push_error("VitureGlasses: ", p_message);
	return false;
}

String VitureGlasses::resolve_library_path() const {
	if (!library_path.begins_with("res://") && !library_path.begins_with("user://")) {
		return library_path;
	}
	String project_path = ProjectSettings::get_singleton()->globalize_path(library_path);
	if (FileAccess::file_exists(project_path)) {
		return project_path;
	}
	// Exported builds pack res:// into a .pck, so ship the SDK next to the executable.
	String exe_dir = OS::get_singleton()->get_executable_path().get_base_dir();
	String beside_exe = exe_dir.path_join(library_path.get_file());
	if (FileAccess::file_exists(beside_exe)) {
		return beside_exe;
	}
	return project_path;
}

int VitureGlasses::detect_product_id() {
	for (int id : viture::find_connected_product_ids()) {
		if (api.is_product_id_valid(id)) {
			return id;
		}
	}
	return 0;
}

bool VitureGlasses::start() {
	if (running) {
		return true;
	}
	if (active_instance && active_instance != this) {
		return fail("another VitureGlasses node is already running.");
	}

	if (!api.is_loaded()) {
		std::string error;
		if (!api.load(resolve_library_path().utf8().get_data(), error)) {
			return fail(String::utf8(error.c_str()));
		}
		if (api.set_log_level) {
			api.set_log_level(LOG_LEVEL_ERROR);
		}
	}

	int pid = product_id != 0 ? product_id : detect_product_id();
	if (pid == 0) {
		return fail("no supported VITURE glasses found on USB.");
	}

	handle = api.create(pid);
	if (!handle) {
		return fail(vformat("xr_device_provider_create(0x%04x) failed.", pid));
	}
	device_type = api.get_device_type(handle);
	active_instance = this;

	// Lifecycle order follows the SDK demo: Carina needs its DOF type before
	// initialize(); Gen1/Gen2 open the IMU after start().
	if (device_type == DEVICE_TYPE_CARINA && api.set_dof_type_carina) {
		api.set_dof_type_carina(handle, enable_6dof ? 1 : 0);
	}
	// Register before initialize(); the SDK reports state while initializing.
	if (api.register_state_callback) {
		api.register_state_callback(handle, &VitureGlasses::on_state_changed);
	}

	int err = api.initialize(handle, nullptr, nullptr);
	if (err != VITURE_GLASSES_SUCCESS) {
		api.destroy(handle);
		handle = nullptr;
		active_instance = nullptr;
		device_type = DEVICE_TYPE_NONE;
		return fail(vformat("xr_device_provider_initialize failed (%d).", err));
	}
	err = api.start(handle);
	if (err != VITURE_GLASSES_SUCCESS) {
		api.shutdown(handle);
		api.destroy(handle);
		handle = nullptr;
		active_instance = nullptr;
		device_type = DEVICE_TYPE_NONE;
		return fail(vformat("xr_device_provider_start failed (%d).", err));
	}

	if (device_type != DEVICE_TYPE_CARINA && api.register_imu_pose_callback && api.open_imu) {
		api.register_imu_pose_callback(handle, &VitureGlasses::on_imu_pose);
		// Pose-rate support varies by model; use the highest one available.
		int freq = VITURE_IMU_FREQUENCY_HIGH;
		while (freq > VITURE_IMU_FREQUENCY_LOW && api.is_product_support_imu_frequency &&
				!api.is_product_support_imu_frequency(pid, VITURE_IMU_MODE_POSE, freq)) {
			freq--;
		}
		err = api.open_imu(handle, VITURE_IMU_MODE_POSE, static_cast<uint8_t>(freq));
		if (err != VITURE_GLASSES_SUCCESS) {
			UtilityFunctions::push_warning("VitureGlasses: open_imu failed (", err, ").");
		}
	}

	connected_product_id = pid;
	running = true;
	has_pose = false;
	tracking_stable = false;
	last_error = String();
	if (stereo) {
		apply_stereo(true);
	}
	emit_signal("started");
	return true;
}

void VitureGlasses::stop() {
	if (!running) {
		return;
	}
	apply_stereo(false);
	running = false;
	if (device_type != DEVICE_TYPE_CARINA && api.close_imu) {
		api.close_imu(handle, VITURE_IMU_MODE_POSE);
	}
	api.stop(handle);
	api.shutdown(handle);
	api.destroy(handle);
	handle = nullptr;
	active_instance = nullptr;
	device_type = DEVICE_TYPE_NONE;
	connected_product_id = 0;
	tracking_stable = false;
	{
		std::lock_guard<std::mutex> lock(imu_mutex);
		imu_fresh = false;
	}
	emit_signal("stopped");
}

void VitureGlasses::on_state_changed(int p_state_id, int p_value) {
	// Called on an SDK thread; hop to the main thread.
	if (active_instance) {
		active_instance->call_deferred("emit_signal", "state_changed", p_state_id, p_value);
	}
}

void VitureGlasses::on_imu_pose(float *p_data, uint64_t p_timestamp) {
	VitureGlasses *self = active_instance;
	if (!self || !p_data) {
		return;
	}
	// data = [roll, pitch, yaw, qw, qx, qy, qz]; euler in degrees, NWU frame.
	std::lock_guard<std::mutex> lock(self->imu_mutex);
	self->imu_euler = Vector3(p_data[0], p_data[1], p_data[2]);
	self->imu_fresh = true;
}

bool VitureGlasses::poll_raw_pose() {
	if (device_type == DEVICE_TYPE_CARINA) {
		// pose = [px, py, pz, qw, qx, qy, qz], OpenGL axes (same as Godot), metres.
		float p[7] = {};
		int status = 1;
		if (api.get_gl_pose_carina(handle, p, prediction_ms * 1e6, &status) != VITURE_GLASSES_SUCCESS) {
			return false;
		}
		Quaternion q(p[4], p[5], p[6], p[3]);
		if (q.length_squared() < 1e-6) {
			return false;
		}
		tracking_stable = status == 0;
		Vector3 position = enable_6dof ? Vector3(p[0], p[1], p[2]) : Vector3();
		raw_pose = Transform3D(Basis(q.normalized()), position);
		return true;
	}

	Vector3 euler;
	{
		std::lock_guard<std::mutex> lock(imu_mutex);
		if (!imu_fresh) {
			return false;
		}
		euler = imu_euler;
	}
	// NWU: +yaw turns left, +pitch looks down, +roll tilts right. Godot (YXZ):
	// +Y turns left, +X looks up, +Z tilts left.
	Vector3 rotation(-Math::deg_to_rad(euler.y), Math::deg_to_rad(euler.z), -Math::deg_to_rad(euler.x));
	tracking_stable = true;
	raw_pose = Transform3D(Basis::from_euler(rotation, EULER_ORDER_YXZ), Vector3());
	return true;
}

void VitureGlasses::update_pose() {
	if (!running || !poll_raw_pose()) {
		return;
	}
	if (!has_pose) {
		has_pose = true;
		recenter();
	}
	pose = reference.affine_inverse() * raw_pose;
}

void VitureGlasses::set_stereo(bool p_enabled) {
	stereo = p_enabled;
	if (running) {
		apply_stereo(stereo);
	}
}

void VitureGlasses::apply_stereo(bool p_enabled) {
	if (p_enabled == stereo_active || (p_enabled && !is_inside_tree())) {
		return;
	}
	XRServer *xr_server = XRServer::get_singleton();
	if (p_enabled) {
		xr_interface->set_glasses(this);
		xr_server->add_interface(xr_interface);
		xr_interface->initialize();
		get_viewport()->set_use_xr(true);
		set_display_3d(true);
	} else {
		set_display_3d(false);
		if (is_inside_tree()) {
			get_viewport()->set_use_xr(false);
		}
		xr_interface->uninitialize();
		xr_server->remove_interface(xr_interface);
		xr_interface->set_glasses(nullptr);
	}
	stereo_active = p_enabled;
}

void VitureGlasses::recenter() {
	// Re-anchor heading and position only, so the horizon stays level.
	Vector3 forward = -raw_pose.basis.get_column(2);
	real_t yaw = Math::atan2(-forward.x, -forward.z);
	reference = Transform3D(Basis(Vector3(0, 1, 0), yaw), raw_pose.origin);
}

void VitureGlasses::reset_tracking() {
	if (running && device_type == DEVICE_TYPE_CARINA && api.reset_pose_carina) {
		api.reset_pose_carina(handle);
	}
	has_pose = false; // Recenter on the next valid pose.
}

String VitureGlasses::get_market_name() const {
	if (!api.get_market_name || connected_product_id == 0) {
		return String();
	}
	char name[128] = {};
	int length = sizeof(name);
	if (api.get_market_name(connected_product_id, name, &length) != VITURE_GLASSES_SUCCESS) {
		return String();
	}
	return String::utf8(name);
}

String VitureGlasses::get_sdk_version() const {
	if (!api.get_version_string) {
		return String();
	}
	return String::utf8(api.get_version_string());
}

int VitureGlasses::set_display_3d(bool p_enabled) {
	ERR_FAIL_COND_V(!running || !api.switch_dimension, -1);
	return api.switch_dimension(handle, p_enabled);
}

int VitureGlasses::get_display_mode() const {
	ERR_FAIL_COND_V(!running || !api.get_display_mode, -1);
	return api.get_display_mode(handle);
}

int VitureGlasses::set_display_mode(int p_mode) {
	ERR_FAIL_COND_V(!running || !api.set_display_mode, -1);
	return api.set_display_mode(handle, p_mode);
}

int VitureGlasses::get_brightness() const {
	ERR_FAIL_COND_V(!running || !api.get_brightness_level, -1);
	return api.get_brightness_level(handle);
}

int VitureGlasses::set_brightness(int p_level) {
	ERR_FAIL_COND_V(!running || !api.set_brightness_level, -1);
	return api.set_brightness_level(handle, p_level);
}

bool VitureGlasses::extend_desktop() {
	// Same as Win+P > Extend. Needed after a display-mode switch: Windows sees
	// the glasses as a new monitor and doesn't add it to the desktop by itself.
	long result = viture::extend_desktop();
	if (result != 0) {
		UtilityFunctions::push_error("VitureGlasses: SetDisplayConfig(extend) failed (", static_cast<int64_t>(result), ").");
		return false;
	}
	return true;
}

String VitureGlasses::get_glasses_display() {
	return String(viture::find_glasses_display().c_str());
}

void VitureGlasses::_bind_methods() {
	ClassDB::bind_static_method("VitureGlasses", D_METHOD("extend_desktop"), &VitureGlasses::extend_desktop);
	ClassDB::bind_static_method("VitureGlasses", D_METHOD("get_glasses_display"), &VitureGlasses::get_glasses_display);
	ClassDB::bind_method(D_METHOD("start"), &VitureGlasses::start);
	ClassDB::bind_method(D_METHOD("stop"), &VitureGlasses::stop);
	ClassDB::bind_method(D_METHOD("is_running"), &VitureGlasses::is_running);
	ClassDB::bind_method(D_METHOD("get_last_error"), &VitureGlasses::get_last_error);
	ClassDB::bind_method(D_METHOD("get_device_type"), &VitureGlasses::get_device_type);
	ClassDB::bind_method(D_METHOD("get_connected_product_id"), &VitureGlasses::get_connected_product_id);
	ClassDB::bind_method(D_METHOD("get_market_name"), &VitureGlasses::get_market_name);
	ClassDB::bind_method(D_METHOD("get_sdk_version"), &VitureGlasses::get_sdk_version);
	ClassDB::bind_method(D_METHOD("get_pose"), &VitureGlasses::get_pose);
	ClassDB::bind_method(D_METHOD("is_tracking_stable"), &VitureGlasses::is_tracking_stable);
	ClassDB::bind_method(D_METHOD("recenter"), &VitureGlasses::recenter);
	ClassDB::bind_method(D_METHOD("reset_tracking"), &VitureGlasses::reset_tracking);
	ClassDB::bind_method(D_METHOD("set_display_3d", "enabled"), &VitureGlasses::set_display_3d);
	ClassDB::bind_method(D_METHOD("get_display_mode"), &VitureGlasses::get_display_mode);
	ClassDB::bind_method(D_METHOD("set_display_mode", "mode"), &VitureGlasses::set_display_mode);
	ClassDB::bind_method(D_METHOD("get_brightness"), &VitureGlasses::get_brightness);
	ClassDB::bind_method(D_METHOD("set_brightness", "level"), &VitureGlasses::set_brightness);

	ClassDB::bind_method(D_METHOD("set_library_path", "path"), &VitureGlasses::set_library_path);
	ClassDB::bind_method(D_METHOD("get_library_path"), &VitureGlasses::get_library_path);
	ClassDB::bind_method(D_METHOD("set_product_id", "id"), &VitureGlasses::set_product_id);
	ClassDB::bind_method(D_METHOD("get_product_id"), &VitureGlasses::get_product_id);
	ClassDB::bind_method(D_METHOD("set_auto_start", "enabled"), &VitureGlasses::set_auto_start);
	ClassDB::bind_method(D_METHOD("get_auto_start"), &VitureGlasses::get_auto_start);
	ClassDB::bind_method(D_METHOD("set_enable_6dof", "enabled"), &VitureGlasses::set_enable_6dof);
	ClassDB::bind_method(D_METHOD("get_enable_6dof"), &VitureGlasses::get_enable_6dof);
	ClassDB::bind_method(D_METHOD("set_prediction_ms", "ms"), &VitureGlasses::set_prediction_ms);
	ClassDB::bind_method(D_METHOD("get_prediction_ms"), &VitureGlasses::get_prediction_ms);
	ClassDB::bind_method(D_METHOD("set_target", "target"), &VitureGlasses::set_target);
	ClassDB::bind_method(D_METHOD("get_target"), &VitureGlasses::get_target);
	ClassDB::bind_method(D_METHOD("set_stereo", "enabled"), &VitureGlasses::set_stereo);
	ClassDB::bind_method(D_METHOD("get_stereo"), &VitureGlasses::get_stereo);
	ClassDB::bind_method(D_METHOD("get_xr_interface"), &VitureGlasses::get_xr_interface);

	ADD_PROPERTY(PropertyInfo(Variant::STRING, "library_path", PROPERTY_HINT_FILE, "*.dll"), "set_library_path", "get_library_path");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "product_id"), "set_product_id", "get_product_id");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "auto_start"), "set_auto_start", "get_auto_start");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "enable_6dof"), "set_enable_6dof", "get_enable_6dof");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "prediction_ms", PROPERTY_HINT_RANGE, "0,50,0.1,suffix:ms"), "set_prediction_ms", "get_prediction_ms");
	ADD_PROPERTY(PropertyInfo(Variant::NODE_PATH, "target", PROPERTY_HINT_NODE_PATH_VALID_TYPES, "Node3D"), "set_target", "get_target");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "stereo"), "set_stereo", "get_stereo");

	ADD_SIGNAL(MethodInfo("started"));
	ADD_SIGNAL(MethodInfo("stopped"));
	ADD_SIGNAL(MethodInfo("state_changed", PropertyInfo(Variant::INT, "state_id"), PropertyInfo(Variant::INT, "value")));

	BIND_ENUM_CONSTANT(DEVICE_TYPE_NONE);
	BIND_ENUM_CONSTANT(DEVICE_TYPE_GEN1);
	BIND_ENUM_CONSTANT(DEVICE_TYPE_GEN2);
	BIND_ENUM_CONSTANT(DEVICE_TYPE_CARINA);
}
