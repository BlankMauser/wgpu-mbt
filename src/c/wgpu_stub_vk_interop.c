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
// features: the WGPUFeatureName values the owner's VkDevice was created with
// (count 0: none); default limits.
WGPUDevice mbt_wgpu_vk_create_device(WGPUAdapter adapter, void *handles, const uint32_t *features,
                                     uint64_t feature_count) {
  pfn_create_device f = (pfn_create_device)mbt_wgpu_optional_sym(MBT_VK_SYMS[2]);
  if (!f || !handles || !adapter) return NULL;
  WGPUDeviceDescriptor desc = WGPU_DEVICE_DESCRIPTOR_INIT;
  desc.requiredFeatureCount = (size_t)feature_count;
  desc.requiredFeatures = (const WGPUFeatureName *)features;
  return f(adapter, &((mbt_vk_handles *)handles)->h, feature_count ? &desc : NULL);
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

// Layout must match WGPUVulkanHandoffExt in wgpu_vk_interop.h.
typedef struct mbt_WGPUVulkanHandoffExt {
  uint32_t structSize;
  mbt_WGPUVulkanDeviceHandlesExt device;
  uint64_t image;
  uint32_t width;
  uint32_t height;
  uint32_t format;
  uint64_t usage;
  uint64_t state;
  void (*lock)(void *);
  void (*unlock)(void *);
  void *lockContext;
  // Appended fields: read only when structSize covers them.
  size_t featureCount;
  const uint32_t *features;
} mbt_WGPUVulkanHandoffExt;

// The first layout (before the appended features): the minimum readable.
#define MBT_HANDOFF_MIN_SIZE offsetof(mbt_WGPUVulkanHandoffExt, featureCount)

static const mbt_WGPUVulkanHandoffExt *mbt_handoff(uint64_t p) {
  return (const mbt_WGPUVulkanHandoffExt *)(uintptr_t)p;
}

// 1: a handoff this build can read (non-null, structSize covers the layout).
int32_t mbt_wgpu_vk_handoff_valid(uint64_t p) {
  return p != 0 && mbt_handoff(p)->structSize >= MBT_HANDOFF_MIN_SIZE;
}

uint64_t mbt_wgpu_vk_handoff_u64(uint64_t p, int32_t field) {
  const mbt_WGPUVulkanHandoffExt *h = mbt_handoff(p);
  switch (field) {
    case 0: return (uint64_t)(uintptr_t)h->device.getInstanceProcAddr;
    case 1: return h->device.instance;
    case 2: return h->device.instanceApiVersion;
    case 3: return h->device.physicalDevice;
    case 4: return h->device.device;
    case 5: return h->device.queueFamilyIndex;
    case 6: return h->device.queueIndex;
    case 7: return h->image;
    case 8: return h->width;
    case 9: return h->height;
    case 10: return h->format;
    case 11: return h->usage;
    case 12: return h->state;
    case 13: return h->lock != NULL && h->unlock != NULL;
    default: return 0;
  }
}

// Instance (which 0) or device (1) extension names, NUL-terminated back to
// back: the length, and a copy into out when capacity suffices.
uint64_t mbt_wgpu_vk_handoff_names(uint64_t p, int32_t which, moonbit_bytes_t out, uint64_t capacity) {
  const mbt_WGPUVulkanHandoffExt *h = mbt_handoff(p);
  size_t count = which ? h->device.deviceExtensionCount : h->device.instanceExtensionCount;
  char const *const *names = which ? h->device.deviceExtensions : h->device.instanceExtensions;
  uint64_t n = 0;
  for (size_t i = 0; i < count && names; i++) {
    size_t len = strlen(names[i]) + 1;
    if (out && n + len <= capacity) memcpy(out + n, names[i], len);
    n += len;
  }
  return n;
}

// A copy of the owner's lock (functions + context), independent of the
// handoff struct's lifetime: the owner may free or rebuild the handoff (a
// resize) while the adopted device keeps using its lock. 0 without a lock.
// Lives for the program (24 bytes per adoption).
typedef struct mbt_vk_queue_lock {
  void (*lock)(void *);
  void (*unlock)(void *);
  void *context;
} mbt_vk_queue_lock;

uint64_t mbt_wgpu_vk_handoff_queue_lock(uint64_t p) {
  const mbt_WGPUVulkanHandoffExt *h = mbt_handoff(p);
  if (!h->lock || !h->unlock) return 0;
  mbt_vk_queue_lock *q = (mbt_vk_queue_lock *)malloc(sizeof(mbt_vk_queue_lock));
  if (!q) return 0;
  q->lock = h->lock;
  q->unlock = h->unlock;
  q->context = h->lockContext;
  return (uint64_t)(uintptr_t)q;
}

// The appended features (0 when the writer's layout predates them): the
// count, and a copy into out when capacity suffices.
uint64_t mbt_wgpu_vk_handoff_features(uint64_t p, uint32_t *out, uint64_t capacity) {
  const mbt_WGPUVulkanHandoffExt *h = mbt_handoff(p);
  if (h->structSize < offsetof(mbt_WGPUVulkanHandoffExt, features) + sizeof(h->features)) return 0;
  if (h->featureCount && !h->features) return 0;
  if (out && h->featureCount <= capacity) {
    memcpy(out, h->features, h->featureCount * sizeof(uint32_t));
  }
  return h->featureCount;
}

void mbt_wgpu_vk_queue_lock_lock(uint64_t q) {
  mbt_vk_queue_lock *l = (mbt_vk_queue_lock *)(uintptr_t)q;
  l->lock(l->context);
}

void mbt_wgpu_vk_queue_lock_unlock(uint64_t q) {
  mbt_vk_queue_lock *l = (mbt_vk_queue_lock *)(uintptr_t)q;
  l->unlock(l->context);
}
