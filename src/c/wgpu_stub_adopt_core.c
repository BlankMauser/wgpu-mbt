// Core adoption (BlankMauser/wgpu-native fork, feature adopt-core, branch
// feat/adopt-core): adopt a device, queue and textures a Rust host owns in the
// SAME wgpu-core Global, when wgpu-native is linked as an rlib into the
// host's Cargo graph (one wgpu-core in the process). Every entry point is an
// optional symbol, like the Vulkan interop's: absent in the stock static
// archive (MBT_WGPU_STATIC_HAS_ADOPT_CORE=0), the calls return NULL and the
// MoonBit side raises WgpuNativeMissingSymbol.

#include "wgpu_stub.h"
#include "wgpu_optional_sym.h"

#include <stdlib.h>
#include <string.h>

typedef WGPUInstance (*pfn_core_instance)(const void *);
typedef WGPUAdapter (*pfn_core_adapter)(WGPUInstance, uint64_t);
typedef WGPUDevice (*pfn_core_device)(WGPUAdapter, uint64_t, uint64_t, WGPUDeviceDescriptor const *);

// The callbacks every device this layer opens gets (wgpu_stub_helpers_sync.c): without them
// wgpu-native's defaults treat an uncaptured error or a device loss as fatal (a panic).
void mbt_uncaptured_error_noop_cb(WGPUDevice const *device, WGPUErrorType type, WGPUStringView message,
                                  void *userdata1, void *userdata2);
void mbt_device_lost_cb(WGPUDevice const *device, WGPUDeviceLostReason reason, WGPUStringView message,
                        void *userdata1, void *userdata2);
typedef WGPUTexture (*pfn_core_texture)(WGPUDevice, uint64_t, WGPUTextureDescriptor const *);
typedef size_t (*pfn_core_error)(char *, size_t);

static const char *const MBT_CORE_SYMS[] = {
    "wgpuCreateInstanceFromCoreExt",
    "wgpuInstanceAdoptAdapterExt",
    "wgpuAdapterAdoptDeviceExt",
    "wgpuDeviceAdoptTextureExt",
    "wgpuCoreAdoptLastErrorExt",
};

int32_t mbt_wgpu_core_adopt_available(void) {
  for (size_t i = 0; i < sizeof(MBT_CORE_SYMS) / sizeof(MBT_CORE_SYMS[0]); i++) {
    if (!mbt_wgpu_optional_sym(MBT_CORE_SYMS[i])) return 0;
  }
  return 1;
}

WGPUInstance mbt_wgpu_core_instance(uint64_t global) {
  pfn_core_instance f = (pfn_core_instance)mbt_wgpu_optional_sym(MBT_CORE_SYMS[0]);
  if (!f || !global) return NULL;
  return f((const void *)(uintptr_t)global);
}

WGPUAdapter mbt_wgpu_core_adapter(WGPUInstance instance, uint64_t adapter_id) {
  pfn_core_adapter f = (pfn_core_adapter)mbt_wgpu_optional_sym(MBT_CORE_SYMS[1]);
  if (!f || !instance) return NULL;
  return f(instance, adapter_id);
}

WGPUDevice mbt_wgpu_core_device(WGPUAdapter adapter, uint64_t device_id, uint64_t queue_id) {
  pfn_core_device f = (pfn_core_device)mbt_wgpu_optional_sym(MBT_CORE_SYMS[2]);
  if (!f || !adapter) return NULL;
  WGPUDeviceDescriptor desc = WGPU_DEVICE_DESCRIPTOR_INIT;
  desc.deviceLostCallbackInfo = (WGPUDeviceLostCallbackInfo){
      .nextInChain = NULL,
      .mode = WGPUCallbackMode_AllowSpontaneous,
      .callback = mbt_device_lost_cb,
      .userdata1 = NULL,
      .userdata2 = NULL,
  };
  desc.uncapturedErrorCallbackInfo = (WGPUUncapturedErrorCallbackInfo){
      .nextInChain = NULL,
      .callback = mbt_uncaptured_error_noop_cb,
      .userdata1 = NULL,
      .userdata2 = NULL,
  };
  return f(adapter, device_id, queue_id, &desc);
}

WGPUTexture mbt_wgpu_core_texture(WGPUDevice device, uint64_t texture_id, uint32_t width,
                                  uint32_t height, uint32_t format, uint64_t usage) {
  pfn_core_texture f = (pfn_core_texture)mbt_wgpu_optional_sym(MBT_CORE_SYMS[3]);
  if (!f || !device) return NULL;
  WGPUTextureDescriptor td = WGPU_TEXTURE_DESCRIPTOR_INIT;
  td.label = (WGPUStringView){"core-adopted", WGPU_STRLEN};
  td.usage = (WGPUTextureUsage)usage;
  td.dimension = WGPUTextureDimension_2D;
  td.size.width = width;
  td.size.height = height;
  td.size.depthOrArrayLayers = 1;
  td.format = (WGPUTextureFormat)format;
  td.mipLevelCount = 1;
  td.sampleCount = 1;
  return f(device, texture_id, &td);
}

// The last adoption error of this thread: length, and a copy when it fits.
uint64_t mbt_wgpu_core_last_error(moonbit_bytes_t out, uint64_t capacity) {
  pfn_core_error f = (pfn_core_error)mbt_wgpu_optional_sym(MBT_CORE_SYMS[4]);
  if (!f) return 0;
  return (uint64_t)f((char *)out, (size_t)capacity);
}
