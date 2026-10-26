// Vulkan interop: adopt a VkInstance / VkDevice / VkQueue and VkImages owned
// by another wgpu in the same process (e.g. a Rust host on the wgpu 30
// crate). Needs the BlankMauser/wgpu-native fork (branch wgpu-30-vk-interop),
// which this branch builds and links statically by default; with a stock
// library (MBT_WGPU_NATIVE_SOURCE=official, or a dynamic v29 library) every
// call raises WgpuNativeMissingSymbol and `has_vulkan_interop()` is false.
//
// Handoff protocol (the caller's job): serialise queue submissions with the
// exporter (one thread or a shared lock); the exporter writes a texture once
// before its first handoff; at every handoff both sides agree on one texture
// state: import with it (`initial_state`) and transition back to it
// (`CommandEncoder::transition_texture`) before handing the texture back.
// Nothing adopted here ever destroys the exporter's Vulkan objects.

///|
/// Raw Vulkan handles of the exporter's device, as integers.
pub(all) struct VulkanHandles {
  /// `PFN_vkGetInstanceProcAddr` the exporter loaded.
  get_instance_proc_addr : UInt64
  instance : UInt64
  instance_api_version : UInt
  /// Instance extensions the exporter enabled.
  instance_extensions : Array[String]
  physical_device : UInt64
  device : UInt64
  /// Device extensions the exporter enabled.
  device_extensions : Array[String]
  queue_family_index : UInt
  queue_index : UInt
}

///|
let vk_interop_symbol : String = "wgpuCreateInstanceFromVulkanExt"

///|
/// True when the loaded wgpu-native has the Vulkan interop extension.
pub fn has_vulkan_interop() -> Bool {
  native_ready() && @c.vk_interop_available()
}

///|
fn require_vulkan_interop() -> Unit raise WgpuError {
  require_native()
  if !@c.vk_interop_available() {
    raise WgpuNativeMissingSymbol(vk_interop_symbol, native_diagnostic())
  }
}

///|
fn names_blob(names : Array[String]) -> Bytes {
  let buf = Buffer()
  for n in names {
    buf.write_bytes(utf8_bytes(n))
    buf.write_byte(b'\x00')
  }
  buf.to_bytes()
}

///|
fn with_vk_handles(h : VulkanHandles, f : (@c.OpaquePtr) -> Unit) -> Unit raise WgpuError {
  let inst = names_blob(h.instance_extensions)
  let dev = names_blob(h.device_extensions)
  let p = @c.vk_handles_new(
    h.get_instance_proc_addr,
    h.instance,
    h.instance_api_version,
    inst,
    inst.length().to_uint64(),
    h.physical_device,
    h.device,
    dev,
    dev.length().to_uint64(),
    h.queue_family_index,
    h.queue_index,
  )
  if @c.vk_ptr_is_null(p) {
    raise WgpuNativeUnsupported("out of memory building Vulkan handles")
  }
  f(p)
  @c.vk_handles_free(p)
}

///|
/// An instance over the exporter's `VkInstance` (Vulkan backend only).
pub fn Instance::from_vulkan(h : VulkanHandles) -> Instance raise WgpuError {
  require_vulkan_interop()
  let mut raw : @c.Instance? = None
  with_vk_handles(h, p => raw = Some(@c.vk_create_instance(p)))
  match raw {
    Some(r) if !@c.vk_instance_is_null(r) => { raw: r }
    _ =>
      raise WgpuNativeUnsupported(
        "wgpuCreateInstanceFromVulkanExt failed (see the wgpu-native log)",
      )
  }
}

///|
/// The exporter's `VkPhysicalDevice` as an adapter of `self`, which must come
/// from `Instance::from_vulkan`.
pub fn Instance::adapter_from_vulkan(
  self : Instance,
  h : VulkanHandles,
) -> Adapter raise WgpuError {
  require_vulkan_interop()
  let mut raw : @c.Adapter? = None
  with_vk_handles(h, p => raw = Some(@c.vk_create_adapter(self.raw, p)))
  match raw {
    Some(r) if !@c.adapter_is_null(r) => { raw: r }
    _ =>
      raise WgpuNativeUnsupported(
        "wgpuInstanceCreateAdapterFromVulkanExt failed (see the wgpu-native log)",
      )
  }
}

///|
/// The exporter's `VkDevice` and queue. The exporter's device must have no
/// optional features and WebGPU default limits (wgpu's
/// `DeviceDescriptor::default()`).
pub fn Adapter::device_from_vulkan(
  self : Adapter,
  h : VulkanHandles,
) -> Device raise WgpuError {
  require_vulkan_interop()
  let mut raw : @c.Device? = None
  with_vk_handles(h, p => raw = Some(@c.vk_create_device(self.raw, p)))
  match raw {
    Some(r) if !@c.device_is_null(r) => { raw: r }
    _ =>
      raise WgpuNativeUnsupported(
        "wgpuAdapterCreateDeviceFromVulkanExt failed (see the wgpu-native log)",
      )
  }
}

///|
/// Import the exporter's 2D `VkImage` (1 mip, 1 sample). `usage` must be the
/// usage the exporter created it with; `initial_state` is exactly one
/// `TEXTURE_USAGE_*` flag: the agreed handoff state the image is in now
/// (`TEXTURE_USAGE_NONE`: contents undefined).
pub fn Device::import_vulkan_image(
  self : Device,
  image : UInt64,
  width : UInt,
  height : UInt,
  format : TextureFormat,
  usage : TextureUsage,
  initial_state~ : UInt64,
) -> Texture raise WgpuError {
  require_vulkan_interop()
  let raw = @c.vk_import_image(
    self.raw,
    image,
    width,
    height,
    format.to_u32(),
    usage.to_u64(),
    initial_state,
  )
  if @c.vk_texture_is_null(raw) {
    raise WgpuNativeUnsupported("wgpuDeviceImportVulkanImageExt failed")
  }
  { raw, }
}

///|
/// Record a transition of the whole texture to one `TEXTURE_USAGE_*` state
/// (wgpu's `CommandEncoder::transition_resources`), for handing it back.
pub fn CommandEncoder::transition_texture(
  self : CommandEncoder,
  texture : Texture,
  state : UInt64,
) -> Unit raise WgpuError {
  require_vulkan_interop()
  if !@c.vk_transition_texture(self.raw, texture.raw, state) {
    raise WgpuNativeMissingSymbol(
      "wgpuCommandEncoderTransitionTextureExt",
      native_diagnostic(),
    )
  }
}
