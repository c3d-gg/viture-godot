#include "desktop_capture.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <unknwn.h> // Must precede the WinRT headers for classic COM interop.
#include <d3d11.h>
#include <dxgi1_2.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>

#include <cstring>
#include <memory>
#include <vector>

using namespace godot;
namespace wgc = winrt::Windows::Graphics::Capture;
namespace wgd = winrt::Windows::Graphics::DirectX;

struct DesktopCapture::Impl {
	winrt::com_ptr<ID3D11Device> device;
	winrt::com_ptr<ID3D11DeviceContext> context;
	winrt::com_ptr<ID3D11Texture2D> staging;
	wgd::Direct3D11::IDirect3DDevice winrt_device{ nullptr };
	wgc::GraphicsCaptureItem item{ nullptr };
	wgc::Direct3D11CaptureFramePool pool{ nullptr };
	wgc::GraphicsCaptureSession session{ nullptr };
	winrt::Windows::Graphics::SizeInt32 pool_size{};
};

namespace {

struct MonitorInfo {
	HMONITOR handle;
	String name;
};

// Desktop-attached monitors across all adapters, in DXGI order.
std::vector<MonitorInfo> enumerate_monitors() {
	std::vector<MonitorInfo> result;
	winrt::com_ptr<IDXGIFactory1> factory;
	if (FAILED(CreateDXGIFactory1(__uuidof(IDXGIFactory1), factory.put_void()))) {
		return result;
	}
	winrt::com_ptr<IDXGIAdapter1> adapter;
	for (UINT a = 0; factory->EnumAdapters1(a, adapter.put()) != DXGI_ERROR_NOT_FOUND; a++) {
		winrt::com_ptr<IDXGIOutput> output;
		for (UINT o = 0; adapter->EnumOutputs(o, output.put()) != DXGI_ERROR_NOT_FOUND; o++) {
			DXGI_OUTPUT_DESC desc;
			output->GetDesc(&desc);
			if (desc.AttachedToDesktop) {
				const RECT &r = desc.DesktopCoordinates;
				result.push_back({ desc.Monitor,
						vformat("%s %dx%d at (%d, %d)", String(desc.DeviceName), r.right - r.left, r.bottom - r.top, r.left, r.top) });
			}
			output = nullptr;
		}
		adapter = nullptr;
	}
	return result;
}

String describe_error(const winrt::hresult_error &p_error) {
	return vformat("0x%08x %s", static_cast<uint32_t>(p_error.code()), String(p_error.message().c_str()));
}

} // namespace

DesktopCapture::~DesktopCapture() {
	stop();
}

PackedStringArray DesktopCapture::get_monitor_names() {
	PackedStringArray names;
	for (const MonitorInfo &m : enumerate_monitors()) {
		names.push_back(m.name);
	}
	return names;
}

bool DesktopCapture::fail(const String &p_message) {
	last_error = p_message;
	UtilityFunctions::push_error("DesktopCapture: ", p_message);
	stop();
	return false;
}

bool DesktopCapture::start(int p_monitor) {
	stop();

	try {
		winrt::init_apartment(winrt::apartment_type::single_threaded);
	} catch (const winrt::hresult_error &) {
		// Already initialized in another apartment mode; WinRT still works.
	}
	if (!wgc::GraphicsCaptureSession::IsSupported()) {
		return fail("Windows Graphics Capture is not supported on this system.");
	}

	std::vector<MonitorInfo> monitors = enumerate_monitors();
	if (p_monitor < 0 || p_monitor >= static_cast<int>(monitors.size())) {
		return fail(vformat("monitor %d does not exist (%d attached).", p_monitor, monitors.size()));
	}
	const MonitorInfo &target = monitors[p_monitor];

	auto im = std::make_unique<Impl>();
	HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
			nullptr, 0, D3D11_SDK_VERSION, im->device.put(), nullptr, im->context.put());
	if (FAILED(hr)) {
		return fail(vformat("D3D11CreateDevice failed (0x%08x).", static_cast<uint32_t>(hr)));
	}

	try {
		auto dxgi_device = im->device.as<IDXGIDevice>();
		winrt::com_ptr<::IInspectable> inspectable;
		winrt::check_hresult(CreateDirect3D11DeviceFromDXGIDevice(dxgi_device.get(), inspectable.put()));
		im->winrt_device = inspectable.as<wgd::Direct3D11::IDirect3DDevice>();

		auto interop = winrt::get_activation_factory<wgc::GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
		winrt::check_hresult(interop->CreateForMonitor(target.handle, winrt::guid_of<wgc::GraphicsCaptureItem>(), winrt::put_abi(im->item)));

		im->pool_size = im->item.Size();
		im->pool = wgc::Direct3D11CaptureFramePool::CreateFreeThreaded(
				im->winrt_device, wgd::DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, im->pool_size);
		im->session = im->pool.CreateCaptureSession(im->item);
		im->session.IsCursorCaptureEnabled(true);
		im->session.StartCapture();
	} catch (const winrt::hresult_error &e) {
		return fail(vformat("capture setup failed for %s: %s", target.name, describe_error(e)));
	}

	impl = im.release();
	if (!resize(impl->pool_size.Width, impl->pool_size.Height)) {
		return false;
	}
	last_error = String();
	return true;
}

bool DesktopCapture::resize(int p_width, int p_height) {
	impl->staging = nullptr;
	D3D11_TEXTURE2D_DESC desc = {};
	desc.Width = p_width;
	desc.Height = p_height;
	desc.MipLevels = 1;
	desc.ArraySize = 1;
	desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
	desc.SampleDesc.Count = 1;
	desc.Usage = D3D11_USAGE_STAGING;
	desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
	HRESULT hr = impl->device->CreateTexture2D(&desc, nullptr, impl->staging.put());
	if (FAILED(hr)) {
		return fail(vformat("CreateTexture2D (staging) failed (0x%08x).", static_cast<uint32_t>(hr)));
	}

	size = Vector2i(p_width, p_height);
	pixels.resize(size.x * size.y * 4);
	image = Image::create_empty(size.x, size.y, false, Image::FORMAT_RGBA8);
	// A new texture when the size changes: ImageTexture::update can't resize.
	texture = ImageTexture::create_from_image(image);
	return true;
}

void DesktopCapture::stop() {
	if (!impl) {
		return;
	}
	try {
		if (impl->session) {
			impl->session.Close();
		}
		if (impl->pool) {
			impl->pool.Close();
		}
	} catch (const winrt::hresult_error &) {
	}
	delete impl;
	impl = nullptr;
}

bool DesktopCapture::update() {
	if (!impl) {
		return false;
	}

	try {
		// Drain the pool and keep only the newest frame.
		wgc::Direct3D11CaptureFrame frame{ nullptr };
		for (auto next = impl->pool.TryGetNextFrame(); next; next = impl->pool.TryGetNextFrame()) {
			frame = next;
		}
		if (!frame) {
			return false;
		}

		auto content = frame.ContentSize();
		if (content.Width != impl->pool_size.Width || content.Height != impl->pool_size.Height) {
			// Monitor resolution changed.
			impl->pool_size = content;
			impl->pool.Recreate(impl->winrt_device, wgd::DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, content);
			resize(content.Width, content.Height);
			return false;
		}

		auto access = frame.Surface().as<::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
		winrt::com_ptr<ID3D11Texture2D> surface;
		winrt::check_hresult(access->GetInterface(__uuidof(ID3D11Texture2D), surface.put_void()));
		impl->context->CopyResource(impl->staging.get(), surface.get());
	} catch (const winrt::hresult_error &e) {
		fail(vformat("capture failed: %s", describe_error(e)));
		return false;
	}

	D3D11_MAPPED_SUBRESOURCE mapped;
	if (FAILED(impl->context->Map(impl->staging.get(), 0, D3D11_MAP_READ, 0, &mapped))) {
		return false;
	}
	uint8_t *dst = pixels.ptrw();
	const uint8_t *src = static_cast<const uint8_t *>(mapped.pData);
	const size_t row = size.x * 4;
	for (int y = 0; y < size.y; y++) {
		memcpy(dst + y * row, src + y * mapped.RowPitch, row);
	}
	impl->context->Unmap(impl->staging.get(), 0);

	image->set_data(size.x, size.y, false, Image::FORMAT_RGBA8, pixels);
	texture->update(image);
	return true;
}

void DesktopCapture::_bind_methods() {
	ClassDB::bind_static_method("DesktopCapture", D_METHOD("get_monitor_names"), &DesktopCapture::get_monitor_names);
	ClassDB::bind_method(D_METHOD("start", "monitor"), &DesktopCapture::start);
	ClassDB::bind_method(D_METHOD("stop"), &DesktopCapture::stop);
	ClassDB::bind_method(D_METHOD("is_capturing"), &DesktopCapture::is_capturing);
	ClassDB::bind_method(D_METHOD("get_last_error"), &DesktopCapture::get_last_error);
	ClassDB::bind_method(D_METHOD("update"), &DesktopCapture::update);
	ClassDB::bind_method(D_METHOD("get_texture"), &DesktopCapture::get_texture);
	ClassDB::bind_method(D_METHOD("get_size"), &DesktopCapture::get_size);
}
