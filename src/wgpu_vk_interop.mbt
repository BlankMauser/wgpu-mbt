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
/// The message wgpu-native left for the last refused interop call.
fn interop_error(what : String) -> WgpuError {
  let n = @c.vk_last_error(Bytes::make(0, b'\x00'), 0UL)
  if n == 0UL {
    return WgpuVulkanInterop("\{what} failed")
  }
  let buf = Bytes::make(n.to_int(), b'\x00')
  ignore(@c.vk_last_error(buf, n))
  WgpuVulkanInterop(@utf8.decode_lossy(buf[:]))
}

///|
/// A handoff state is exactly one known `TEXTURE_USAGE_*` flag (or
/// `TEXTURE_USAGE_NONE` for an import whose contents do not matter).
fn check_state(state : UInt64, usage : UInt64?) -> Unit raise WgpuError {
  let known = [
    TEXTURE_USAGE_NONE, TEXTURE_USAGE_COPY_SRC, TEXTURE_USAGE_COPY_DST, TEXTURE_USAGE_TEXTURE_BINDING,
    TEXTURE_USAGE_STORAGE_BINDING, TEXTURE_USAGE_RENDER_ATTACHMENT,
  ]
  if !known.contains(state) {
    raise WgpuVulkanInterop(
      "state 0x\{state.to_string(radix=16)} is not exactly one TEXTURE_USAGE_* flag",
    )
  }
  if usage is Some(u) && state != TEXTURE_USAGE_NONE && (u & state) == 0UL {
    raise WgpuVulkanInterop(
      "state 0x\{state.to_string(radix=16)} is not part of the texture's usage 0x\{u.to_string(radix=16)}",
    )
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
    _ => raise interop_error("wgpuCreateInstanceFromVulkanExt")
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
    _ => raise interop_error("wgpuInstanceCreateAdapterFromVulkanExt")
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
    _ => raise interop_error("wgpuAdapterCreateDeviceFromVulkanExt")
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
  check_state(initial_state, Some(usage.to_u64()))
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
    raise interop_error("wgpuDeviceImportVulkanImageExt")
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
  check_state(state, None)
  if !@c.vk_transition_texture(self.raw, texture.raw, state) {
    raise interop_error("wgpuCommandEncoderTransitionTextureExt")
  }
}

///|
/// A `WGPUVulkanHandoffExt` the owner built from its own objects (Rust:
/// wgpu-native's crates/wgpu-vk-handoff): device handles, the shared image
/// with its size, format, usage and handoff state, and the owner's queue
/// lock. Read through the pointer, which stays valid while the owner keeps
/// the handoff alive.
pub struct VulkanHandoff {
  raw : UInt64
}

///|
/// Raises unless `ptr` points at a handoff this build can read.
pub fn VulkanHandoff::from_ptr(ptr : UInt64) -> VulkanHandoff raise WgpuError {
  if !@c.vk_handoff_valid(ptr) {
    raise WgpuVulkanInterop(
      "not a WGPUVulkanHandoffExt (null, or structSize smaller than this build's layout)",
    )
  }
  { raw: ptr }
}

///|
fn VulkanHandoff::field(self : VulkanHandoff, i : Int) -> UInt64 {
  @c.vk_handoff_u64(self.raw, i)
}

///|
fn VulkanHandoff::names(self : VulkanHandoff, which : Int) -> Array[String] {
  let n = @c.vk_handoff_names(self.raw, which, Bytes::make(0, b'\x00'), 0UL)
  let buf = Bytes::make(n.to_int(), b'\x00')
  ignore(@c.vk_handoff_names(self.raw, which, buf, n))
  let out = []
  let mut start = 0
  for i in 0..<buf.length() {
    if buf[i] == b'\x00' {
      out.push(@utf8.decode_lossy(buf[start:i]))
      start = i + 1
    }
  }
  out
}

///|
/// The device handles (for `Instance::from_vulkan` and the rest).
pub fn VulkanHandoff::handles(self : VulkanHandoff) -> VulkanHandles {
  {
    get_instance_proc_addr: self.field(0),
    instance: self.field(1),
    instance_api_version: self.field(2).to_uint(),
    instance_extensions: self.names(0),
    physical_device: self.field(3),
    device: self.field(4),
    device_extensions: self.names(1),
    queue_family_index: self.field(5).to_uint(),
    queue_index: self.field(6).to_uint(),
  }
}

///|
pub fn VulkanHandoff::image(self : VulkanHandoff) -> UInt64 {
  self.field(7)
}

///|
pub fn VulkanHandoff::width(self : VulkanHandoff) -> UInt {
  self.field(8).to_uint()
}

///|
pub fn VulkanHandoff::height(self : VulkanHandoff) -> UInt {
  self.field(9).to_uint()
}

///|
pub fn VulkanHandoff::format(self : VulkanHandoff) -> TextureFormat {
  TextureFormat::from_u32(self.field(10).to_uint())
}

///|
pub fn VulkanHandoff::usage(self : VulkanHandoff) -> TextureUsage {
  TextureUsage::from_u64(self.field(11))
}

///|
/// The agreed handoff state (one `TEXTURE_USAGE_*` flag).
pub fn VulkanHandoff::state(self : VulkanHandoff) -> UInt64 {
  self.field(12)
}

///|
/// The owner exported its queue lock.
pub fn VulkanHandoff::has_lock(self : VulkanHandoff) -> Bool {
  self.field(13) != 0UL
}

///|
/// Takes the owner's queue lock (no-op without one).
pub fn VulkanHandoff::lock(self : VulkanHandoff) -> Unit {
  @c.vk_handoff_lock(self.raw)
}

///|
pub fn VulkanHandoff::unlock(self : VulkanHandoff) -> Unit {
  @c.vk_handoff_unlock(self.raw)
}
