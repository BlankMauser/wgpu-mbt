// Vulkan interop externs (wgpu_stub_vk_interop.c). All entry points are
// optional symbols of the BlankMauser/wgpu-native fork; with a stock library
// they return NULL / false.

///|
pub extern "C" fn vk_interop_available() -> Bool = "mbt_wgpu_vk_interop_available"

///|
/// `inst_exts` / `dev_exts`: NUL-terminated extension names back to back.
#borrow(inst_exts, dev_exts)
pub extern "C" fn vk_handles_new(
  get_instance_proc_addr : UInt64,
  instance : UInt64,
  instance_api_version : UInt,
  inst_exts : Bytes,
  inst_len : UInt64,
  physical_device : UInt64,
  device : UInt64,
  dev_exts : Bytes,
  dev_len : UInt64,
  queue_family_index : UInt,
  queue_index : UInt,
) -> OpaquePtr = "mbt_wgpu_vk_handles_new"

///|
pub extern "C" fn vk_handles_free(handles : OpaquePtr) -> Unit = "mbt_wgpu_vk_handles_free"

///|
#borrow(handles)
pub extern "C" fn vk_create_instance(handles : OpaquePtr) -> Instance = "mbt_wgpu_vk_create_instance"

///|
#borrow(instance, handles)
pub extern "C" fn vk_create_adapter(
  instance : Instance,
  handles : OpaquePtr,
) -> Adapter = "mbt_wgpu_vk_create_adapter"

///|
#borrow(adapter, handles)
pub extern "C" fn vk_create_device(
  adapter : Adapter,
  handles : OpaquePtr,
) -> Device = "mbt_wgpu_vk_create_device"

///|
#borrow(device)
pub extern "C" fn vk_import_image(
  device : Device,
  image : UInt64,
  width : UInt,
  height : UInt,
  format : UInt,
  usage : UInt64,
  initial_state : UInt64,
) -> Texture = "mbt_wgpu_vk_import_image"

///|
#borrow(encoder, texture)
pub extern "C" fn vk_transition_texture(
  encoder : CommandEncoder,
  texture : Texture,
  state : UInt64,
) -> Bool = "mbt_wgpu_vk_transition_texture"

///|
/// This thread's last interop error: its length; copied into `out` when
/// `capacity` suffices.
#borrow(out)
pub extern "C" fn vk_last_error(out : Bytes, capacity : UInt64) -> UInt64 = "mbt_wgpu_vk_last_error"

///|
#borrow(p)
pub extern "C" fn vk_instance_is_null(p : Instance) -> Bool = "mbt_wgpu_vk_instance_is_null"

///|
#borrow(p)
pub extern "C" fn vk_texture_is_null(p : Texture) -> Bool = "mbt_wgpu_vk_texture_is_null"

///|
#borrow(p)
pub extern "C" fn vk_ptr_is_null(p : OpaquePtr) -> Bool = "mbt_wgpu_vk_ptr_is_null"

///|
pub extern "C" fn vk_handoff_valid(p : UInt64) -> Bool = "mbt_wgpu_vk_handoff_valid"

///|
pub extern "C" fn vk_handoff_u64(p : UInt64, field : Int) -> UInt64 = "mbt_wgpu_vk_handoff_u64"

///|
#borrow(out)
pub extern "C" fn vk_handoff_names(p : UInt64, which : Int, out : Bytes, capacity : UInt64) -> UInt64 = "mbt_wgpu_vk_handoff_names"

///|
pub extern "C" fn vk_handoff_queue_lock(p : UInt64) -> UInt64 = "mbt_wgpu_vk_handoff_queue_lock"

///|
pub extern "C" fn vk_queue_lock_lock(q : UInt64) -> Unit = "mbt_wgpu_vk_queue_lock_lock"

///|
pub extern "C" fn vk_queue_lock_unlock(q : UInt64) -> Unit = "mbt_wgpu_vk_queue_lock_unlock"
