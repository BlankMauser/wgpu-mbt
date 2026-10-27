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

///|
test "vulkan interop: handoff states are exactly one known flag, part of the usage" {
  let refused = fn(state : UInt64, usage : UInt64?) -> Bool {
    try {
      check_state(state, usage)
      false
    } catch {
      WgpuVulkanInterop(_) => true
      _ => false
    }
  }
  assert_true(refused(TEXTURE_USAGE_TEXTURE_BINDING | TEXTURE_USAGE_COPY_SRC, None))
  assert_true(refused(0x40UL, None))
  assert_true(refused(TEXTURE_USAGE_COPY_DST, Some(TEXTURE_USAGE_TEXTURE_BINDING)))
  assert_false(refused(TEXTURE_USAGE_TEXTURE_BINDING, Some(TEXTURE_USAGE_TEXTURE_BINDING | TEXTURE_USAGE_COPY_SRC)))
  assert_false(refused(TEXTURE_USAGE_NONE, Some(TEXTURE_USAGE_COPY_SRC)))
}
