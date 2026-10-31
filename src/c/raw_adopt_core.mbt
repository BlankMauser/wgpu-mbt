// Core adoption externs (wgpu_stub_adopt_core.c). All entry points are
// optional symbols of the BlankMauser/wgpu-native fork's `adopt-core` feature;
// without it they return NULL / false.

///|
pub extern "C" fn core_adopt_available() -> Bool = "mbt_wgpu_core_adopt_available"

///|
/// `global`: `Arc::as_ptr` of the host's live `Arc<wgpu_core::global::Global>`.
pub extern "C" fn core_create_instance(global : UInt64) -> Instance = "mbt_wgpu_core_instance"

///|
#borrow(instance)
pub extern "C" fn core_adopt_adapter(
  instance : Instance,
  adapter_id : UInt64,
) -> Adapter = "mbt_wgpu_core_adapter"

///|
#borrow(adapter)
pub extern "C" fn core_adopt_device(
  adapter : Adapter,
  device_id : UInt64,
  queue_id : UInt64,
) -> Device = "mbt_wgpu_core_device"

///|
#borrow(device)
pub extern "C" fn core_adopt_texture(
  device : Device,
  texture_id : UInt64,
  width : UInt32,
  height : UInt32,
  format : UInt32,
  usage : UInt64,
) -> Texture = "mbt_wgpu_core_texture"

///|
#borrow(out)
pub extern "C" fn core_last_error(out : Bytes, capacity : UInt64) -> UInt64 = "mbt_wgpu_core_last_error"
