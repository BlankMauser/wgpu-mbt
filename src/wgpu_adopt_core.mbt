// Core adoption: a device, queue and textures a Rust host owns in the SAME
// wgpu-core `Global` (the host's `wgpu` 30 crate and wgpu-native linked into
// one binary, one wgpu-core). Needs the BlankMauser/wgpu-native fork built as an
// rlib with its `adopt-core` feature; with the default static archive every
// call raises WgpuNativeMissingSymbol and `has_core_adoption()` is false.
//
// No handoff protocol: one device, one queue and one resource tracker. The
// host keeps every id; handles adopted here never drop, poll or destroy
// them, and the host keeps its objects alive until these are released.

///|
let core_adopt_symbol : String = "wgpuCreateInstanceFromCoreExt"

///|
/// True when the linked wgpu-native has the `adopt-core` entry points.
pub fn has_core_adoption() -> Bool {
  native_ready() && @c.core_adopt_available()
}

///|
fn require_core_adoption() -> Unit raise WgpuError {
  require_native()
  if !@c.core_adopt_available() {
    raise WgpuNativeMissingSymbol(core_adopt_symbol, native_diagnostic())
  }
}

///|
fn core_error(what : String) -> WgpuError {
  let n = @c.core_last_error(Bytes::make(0, b'\x00'), 0UL)
  if n == 0UL {
    return WgpuCoreAdopt("\{what} failed")
  }
  let buf = Bytes::make(n.to_int(), b'\x00')
  ignore(@c.core_last_error(buf, n))
  WgpuCoreAdopt(@utf8.decode_lossy(buf[:]))
}

///|
/// An instance over the host's wgpu-core `Global`. `global` is
/// `Arc::as_ptr` of the host's live `Arc<Global>` (ShibaPan's
/// `Instance::as_core_global`); the instance takes its own strong count.
pub fn Instance::from_core(global : UInt64) -> Instance raise WgpuError {
  require_core_adoption()
  let raw = @c.core_create_instance(global)
  if @c.vk_instance_is_null(raw) {
    raise core_error("wgpuCreateInstanceFromCoreExt")
  }
  { raw, }
}

///|
/// The host's adapter (its wgpu-core id, `wgpu_native::adopt_core::id_to_u64`)
/// as an adapter of `self`, which must come from `Instance::from_core`.
pub fn Instance::adapter_from_core(
  self : Instance,
  adapter_id : UInt64,
) -> Adapter raise WgpuError {
  require_core_adoption()
  let raw = @c.core_adopt_adapter(self.raw, adapter_id)
  if @c.adapter_is_null(raw) {
    raise core_error("wgpuInstanceAdoptAdapterExt")
  }
  { raw, }
}

///|
/// The host's device and queue. Features and limits are the host's own. A
/// device that is lost, not on this adapter, or an id that is not live raises.
pub fn Adapter::device_from_core(
  self : Adapter,
  device_id : UInt64,
  queue_id : UInt64,
) -> Device raise WgpuError {
  require_core_adoption()
  let raw = @c.core_adopt_device(self.raw, device_id, queue_id)
  if @c.device_is_null(raw) {
    raise core_error("wgpuAdapterAdoptDeviceExt")
  }
  { raw, }
}

///|
/// The host's 2D texture (1 mip, 1 sample) as a texture of `self`. `usage` and
/// `format` must be the texture's own (wgpu-core cannot report them back).
/// A texture that is gone or destroyed raises.
pub fn Device::texture_from_core(
  self : Device,
  texture_id : UInt64,
  width : UInt32,
  height : UInt32,
  format : TextureFormat,
  usage : TextureUsage,
) -> Texture raise WgpuError {
  require_core_adoption()
  let raw = @c.core_adopt_texture(
    self.raw,
    texture_id,
    width,
    height,
    format.to_u32(),
    usage.to_u64(),
  )
  if @c.vk_texture_is_null(raw) {
    raise core_error("wgpuDeviceAdoptTextureExt")
  }
  { raw, }
}
