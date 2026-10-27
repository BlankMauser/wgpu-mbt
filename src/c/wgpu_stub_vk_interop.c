// Vulkan interop (BlankMauser/wgpu-native fork extension, branch
// wgpu-30-vk-interop): adopt a VkInstance/VkDevice/VkQueue and VkImages owned
// by another wgpu (e.g. the Rust wgpu 30 crate) in the same process.
//
// Every entry point is looked up as an optional symbol: in static mode from
// the static symbol table (wgpu_dynload.c, present when the source build has
// the extension: MBT_WGPU_STATIC_HAS_VK_INTEROP), in dynamic mode from the
// loaded library. With a stock wgpu-native (v29.0.1.1, either mode) the calls
// return NULL / 0 and the MoonBit side raises WgpuNativeMissingSymbol.

#include "wgpu_stub.h"
#include "wgpu_optional_sym.h"

#include <stdlib.h>
#include <string.h>

// Layout must match wgpu_vk_interop.h in the wgpu-native fork.
typedef struct mbt_WGPUVulkanDeviceHandlesExt {
  void const *getInstanceProcAddr;
  uint64_t instance;
  uint32_t instanceApiVersion;
  size_t instanceExtensionCount;
  char const *const *instanceExtensions;
  uint64_t physicalDevice;
  uint64_t device;
  size_t deviceExtensionCount;
  char const *const *deviceExtensions;
  uint32_t queueFamilyIndex;
  uint32_t queueIndex;
} mbt_WGPUVulkanDeviceHandlesExt;

typedef struct mbt_vk_handles {
  mbt_WGPUVulkanDeviceHandlesExt h;
  char *inst_blob;
  char *dev_blob;
  char const **inst_names;
  char const **dev_names;
} mbt_vk_handles;

typedef WGPUInstance (*pfn_create_instance)(mbt_WGPUVulkanDeviceHandlesExt const *);
typedef WGPUAdapter (*pfn_create_adapter)(WGPUInstance, mbt_WGPUVulkanDeviceHandlesExt const *);
typedef WGPUDevice (*pfn_create_device)(WGPUAdapter, mbt_WGPUVulkanDeviceHandlesExt const *,
                                        WGPUDeviceDescriptor const *);
typedef WGPUTexture (*pfn_import_image)(WGPUDevice, uint64_t, WGPUTextureDescriptor const *,
                                        WGPUTextureUsage);
typedef WGPUBool (*pfn_transition)(WGPUCommandEncoder, WGPUTexture, WGPUTextureUsage);
typedef size_t (*pfn_last_error)(char *, size_t);

static const char *const MBT_VK_SYMS[] = {
    "wgpuCreateInstanceFromVulkanExt",
    "wgpuInstanceCreateAdapterFromVulkanExt",
    "wgpuAdapterCreateDeviceFromVulkanExt",
    "wgpuDeviceImportVulkanImageExt",
    "wgpuCommandEncoderTransitionTextureExt",
    "wgpuVulkanInteropLastErrorExt",
};

int32_t mbt_wgpu_vk_interop_available(void) {
  for (size_t i = 0; i < sizeof(MBT_VK_SYMS) / sizeof(MBT_VK_SYMS[0]); i++) {
    if (!mbt_wgpu_optional_sym(MBT_VK_SYMS[i])) return 0;
  }
  return 1;
}

// `blob` holds NUL-terminated names back to back (`len` bytes in all).
static char const **mbt_vk_split(const uint8_t *blob, uint64_t len, char **copy, size_t *count) {
  *copy = NULL;
  *count = 0;
  if (len == 0) return NULL;
  *copy = (char *)malloc((size_t)len + 1);
  if (!*copy) return NULL;
  memcpy(*copy, blob, (size_t)len);
  (*copy)[len] = '\0';
  size_t n = 0;
  for (uint64_t i = 0; i < len; i++) {
    if ((*copy)[i] == '\0') n++;
  }
  char const **names = (char const **)calloc(n ? n : 1, sizeof(char *));
  if (!names) return NULL;
  size_t k = 0;
  char *p = *copy;
  while (k < n) {
    names[k++] = p;
    p += strlen(p) + 1;
  }
  *count = n;
  return names;
}

void *mbt_wgpu_vk_handles_new(uint64_t gipa, uint64_t instance, uint32_t api_version,
                              const uint8_t *inst_exts, uint64_t inst_len, uint64_t physical_device,
                              uint64_t device, const uint8_t *dev_exts, uint64_t dev_len,
                              uint32_t family, uint32_t queue_index) {
  mbt_vk_handles *v = (mbt_vk_handles *)calloc(1, sizeof(mbt_vk_handles));
  if (!v) return NULL;
  v->h.getInstanceProcAddr = (void const *)(uintptr_t)gipa;
  v->h.instance = instance;
  v->h.instanceApiVersion = api_version;
  v->inst_names = mbt_vk_split(inst_exts, inst_len, &v->inst_blob, &v->h.instanceExtensionCount);
  v->h.instanceExtensions = v->inst_names;
  v->h.physicalDevice = physical_device;
  v->h.device = device;
  v->dev_names = mbt_vk_split(dev_exts, dev_len, &v->dev_blob, &v->h.deviceExtensionCount);
  v->h.deviceExtensions = v->dev_names;
  v->h.queueFamilyIndex = family;
  v->h.queueIndex = queue_index;
  return v;
}

void mbt_wgpu_vk_handles_free(void *p) {
  mbt_vk_handles *v = (mbt_vk_handles *)p;
  if (!v) return;
  free(v->inst_blob);
  free(v->dev_blob);
  free((void *)v->inst_names);
  free((void *)v->dev_names);
  free(v);
}

WGPUInstance mbt_wgpu_vk_create_instance(void *handles) {
  pfn_create_instance f = (pfn_create_instance)mbt_wgpu_optional_sym(MBT_VK_SYMS[0]);
  if (!f || !handles) return NULL;
  return f(&((mbt_vk_handles *)handles)->h);
}

WGPUAdapter mbt_wgpu_vk_create_adapter(WGPUInstance instance, void *handles) {
  pfn_create_adapter f = (pfn_create_adapter)mbt_wgpu_optional_sym(MBT_VK_SYMS[1]);
  if (!f || !handles || !instance) return NULL;
  return f(instance, &((mbt_vk_handles *)handles)->h);
}

// No descriptor: the exporter's device must have no optional features and
// WebGPU default limits (what wgpu's DeviceDescriptor::default() requests).
WGPUDevice mbt_wgpu_vk_create_device(WGPUAdapter adapter, void *handles) {
  pfn_create_device f = (pfn_create_device)mbt_wgpu_optional_sym(MBT_VK_SYMS[2]);
  if (!f || !handles || !adapter) return NULL;
  return f(adapter, &((mbt_vk_handles *)handles)->h, NULL);
}

WGPUTexture mbt_wgpu_vk_import_image(WGPUDevice device, uint64_t image, uint32_t width,
                                     uint32_t height, uint32_t format, uint64_t usage,
                                     uint64_t initial_state) {
  pfn_import_image f = (pfn_import_image)mbt_wgpu_optional_sym(MBT_VK_SYMS[3]);
  if (!f || !device) return NULL;
  WGPUTextureDescriptor td = WGPU_TEXTURE_DESCRIPTOR_INIT;
  td.label = (WGPUStringView){"vulkan-import", WGPU_STRLEN};
  td.usage = (WGPUTextureUsage)usage;
  td.dimension = WGPUTextureDimension_2D;
  td.size.width = width;
  td.size.height = height;
  td.size.depthOrArrayLayers = 1;
  td.format = (WGPUTextureFormat)format;
  td.mipLevelCount = 1;
  td.sampleCount = 1;
  return f(device, image, &td, (WGPUTextureUsage)initial_state);
}

int32_t mbt_wgpu_vk_transition_texture(WGPUCommandEncoder encoder, WGPUTexture texture,
                                       uint64_t state) {
  pfn_transition f = (pfn_transition)mbt_wgpu_optional_sym(MBT_VK_SYMS[4]);
  if (!f || !encoder || !texture) return 0;
  return f(encoder, texture, (WGPUTextureUsage)state) ? 1 : 0;
}

// The last interop error of this thread: length, and a copy when it fits.
uint64_t mbt_wgpu_vk_last_error(moonbit_bytes_t out, uint64_t capacity) {
  pfn_last_error f = (pfn_last_error)mbt_wgpu_optional_sym(MBT_VK_SYMS[5]);
  if (!f) return 0;
  return (uint64_t)f((char *)out, (size_t)capacity);
}

int32_t mbt_wgpu_vk_instance_is_null(WGPUInstance p) { return p == NULL; }
int32_t mbt_wgpu_vk_texture_is_null(WGPUTexture p) { return p == NULL; }
int32_t mbt_wgpu_vk_ptr_is_null(void *p) { return p == NULL; }
