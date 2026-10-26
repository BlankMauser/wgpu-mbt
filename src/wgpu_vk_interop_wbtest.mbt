///|
test "vulkan interop: absent symbols fail cleanly, present ones are all there" {
  let has = has_vulkan_interop()
  let syms = [
    "wgpuCreateInstanceFromVulkanExt", "wgpuInstanceCreateAdapterFromVulkanExt", "wgpuAdapterCreateDeviceFromVulkanExt",
    "wgpuDeviceImportVulkanImageExt", "wgpuCommandEncoderTransitionTextureExt",
  ]
  assert_eq(has, syms.iter().all(s => native_has_symbol(s)))
  if !has {
    let h : VulkanHandles = {
      get_instance_proc_addr: 0UL,
      instance: 0UL,
      instance_api_version: 0U,
      instance_extensions: [],
      physical_device: 0UL,
      device: 0UL,
      device_extensions: [],
      queue_family_index: 0U,
      queue_index: 0U,
    }
    let refused = try {
      ignore(Instance::from_vulkan(h))
      false
    } catch {
      WgpuNativeMissingSymbol(s, _) => s == "wgpuCreateInstanceFromVulkanExt"
      WgpuNativeUnavailable(_) => true
      _ => false
    }
    assert_true(refused)
  }
  println("has_vulkan_interop=\{has}")
}
