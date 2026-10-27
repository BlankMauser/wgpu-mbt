///|
test "render: LOAD_OP_DONT_CARE colour attachment, a full-screen draw writes every pixel" {
  run_on_supported_native_platform(() => {
    let instance = @wgpu.Instance::create()
    let adapter = instance.request_adapter_sync()
    let device = adapter.request_device_sync(instance)
    let queue = device.queue()
    let tex = device.create_texture_rgba8_2d(4U, 4U)
    let view = tex.create_view()
    let readback = device.create_buffer(
      size=1024UL,
      usage=bu(@wgpu.BUFFER_USAGE_MAP_READ | @wgpu.BUFFER_USAGE_COPY_DST),
    )
    let sm = device.create_shader_module_wgsl(
      (
        #|@vertex fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
        #|  var p = array(vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
        #|  return vec4<f32>(p[i], 0.0, 1.0);
        #|}
        #|@fragment fn fs_main() -> @location(0) vec4<f32> { return vec4<f32>(0.0, 1.0, 0.0, 1.0); }
      ),
    )
    let pipeline = device.create_render_pipeline_rgba8(sm)
    // Fill with red first, so a pass that loaded instead would show it.
    queue.write_texture_rgba8_2d(tex, 4U, 4U, Bytes::makei(64, i => if i % 4 == 0 || i % 4 == 3 { b'\xff' } else { b'\x00' }))
    let encoder = device.create_command_encoder()
    let rb = @wgpu.RenderPassDescBuilder::new(1U)
    rb.set_color_attachment(0U, view, load_op_u32=@wgpu.LOAD_OP_DONT_CARE, store_op_u32=@wgpu.STORE_OP_STORE)
    let pass = rb.begin(encoder)
    rb.free()
    pass.set_pipeline(pipeline)
    pass.draw(3U, 1U, 0U, 0U)
    pass.end()
    pass.release()
    encoder.copy_texture_to_buffer_rgba8(tex, readback, 4U, 4U)
    let cmd = encoder.finish()
    queue.submit_one(cmd)
    let out = readback.readback(instance, 0UL, 4UL * 4UL)
    let px = [out[0].to_uint(), out[1].to_uint(), out[2].to_uint(), out[3].to_uint()]
    @debug.debug_inspect(px, content="[0, 255, 0, 255]")
    println("has_load_op_dont_care=\{@wgpu.has_load_op_dont_care()}")
    cmd.release()
    encoder.release()
    pipeline.release()
    sm.release()
    readback.release()
    view.release()
    tex.release()
    queue.release()
    device.release()
    adapter.release()
    instance.release()
  })
}
