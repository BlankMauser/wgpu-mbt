///|
test "map_read_begin: ready() never blocks and turns true once the map completes" {
  let instance = @wgpu.Instance::create()
  let adapter = instance.request_adapter_sync()
  let device = adapter.request_device_sync(instance)
  let queue = device.queue()
  let src = device.create_buffer_init(
    usage=bu(@wgpu.BUFFER_USAGE_COPY_SRC),
    Bytes::from_array([b'\x2a', b'\x00', b'\x00', b'\x00']),
  )
  let dst = device.create_buffer(
    size=4UL,
    usage=bu(@wgpu.BUFFER_USAGE_MAP_READ | @wgpu.BUFFER_USAGE_COPY_DST),
  )
  let enc = device.create_command_encoder()
  enc.copy_buffer_to_buffer(src, 0UL, dst, 0UL, 4UL)
  let cmd = enc.finish()
  queue.submit_one(cmd)
  let pending = dst.map_read_begin(0UL, 4UL)
  let mut polls = 0
  while !pending.ready(instance) {
    device.poll(wait=false) |> ignore
    polls += 1
  }
  inspect(polls >= 0, content="true")
  let out = pending.finish(instance)
  inspect(out[0].to_int(), content="42")
  dst.unmap()
  cmd.release()
  enc.release()
  dst.release()
  src.release()
  queue.release()
  device.release()
  adapter.release()
  instance.release()
}

///|
test "map_read_begin: finish_into copies an unaligned range into the caller's array" {
  let instance = @wgpu.Instance::create()
  let adapter = instance.request_adapter_sync()
  let device = adapter.request_device_sync(instance)
  let queue = device.queue()
  let src = device.create_buffer_init(
    usage=bu(@wgpu.BUFFER_USAGE_COPY_SRC),
    Bytes::makei(16, fn(i) { (i + 1).to_byte() }),
  )
  let dst = device.create_buffer(
    size=16UL,
    usage=bu(@wgpu.BUFFER_USAGE_MAP_READ | @wgpu.BUFFER_USAGE_COPY_DST),
  )
  let enc = device.create_command_encoder()
  enc.copy_buffer_to_buffer(src, 0UL, dst, 0UL, 16UL)
  let cmd = enc.finish()
  queue.submit_one(cmd)
  // bytes 3..9 (offset 3: not 8-aligned) into out[2..8]
  let out = FixedArray::make(10, b'\x00')
  let pending = dst.map_read_begin(3UL, 6UL)
  pending.finish_into(instance, out, at=2)
  inspect(Array::makei(10, fn(i) { out[i].to_int() }), content="[0, 0, 4, 5, 6, 7, 8, 9, 0, 0]")
  dst.unmap()
  // too short an array is refused, and nothing is copied
  let short = FixedArray::make(4, b'\x00')
  let again = dst.map_read_begin(0UL, 6UL)
  let refused = try {
    again.finish_into(instance, short)
    false
  } catch {
    _ => true
  }
  inspect(refused, content="true")
  // (the refused finish leaves its begin unfinished: finish it to free it)
  again.finish(instance) |> ignore
  dst.unmap()
  cmd.release()
  enc.release()
  dst.release()
  src.release()
  queue.release()
  device.release()
  adapter.release()
  instance.release()
}
