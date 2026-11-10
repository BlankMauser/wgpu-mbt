// Acceleration structures for ray queries (BlankMauser/wgpu-native fork,
// ffi/wgpu_ray_query.h): bottom-level structures (BLAS) of triangle
// geometries, a top-level structure (TLAS) of instances, one build command,
// and TLAS bindings of bind groups (`var scene: acceleration_structure` under
// `enable wgpu_ray_query;` in WGSL).
//
// The device needs `NATIVE_FEATURE_RAY_QUERY`. With a wgpu-native that lacks
// the calls every function here raises WgpuNativeMissingSymbol and
// `has_ray_query_calls()` is false. Validation errors are wgpu's: they reach
// the device's error scopes like any other call's.

///|
/// Buffer usages of BLAS geometry buffers and TLAS instance buffers (wgpu's
/// `BLAS_INPUT`, `TLAS_INPUT`).
pub const BUFFER_USAGE_BLAS_INPUT : UInt64 = 0x400UL

///|
pub const BUFFER_USAGE_TLAS_INPUT : UInt64 = 0x800UL

///|
/// wgpu's `AccelerationStructureFlags`.
pub const ACCELERATION_STRUCTURE_ALLOW_UPDATE : UInt = 1U

///|
pub const ACCELERATION_STRUCTURE_ALLOW_COMPACTION : UInt = 2U

///|
pub const ACCELERATION_STRUCTURE_PREFER_FAST_TRACE : UInt = 4U

///|
pub const ACCELERATION_STRUCTURE_PREFER_FAST_BUILD : UInt = 8U

///|
pub const ACCELERATION_STRUCTURE_LOW_MEMORY : UInt = 16U

///|
let ray_query_symbol : String = "wgpuDeviceCreateBlasExt"

///|
/// The linked wgpu-native has the ray-query calls.
pub fn has_ray_query_calls() -> Bool {
  @c.ray_query_available()
}

///|
fn require_ray_query() -> Unit raise WgpuError {
  require_native()
  if !@c.ray_query_available() {
    raise WgpuNativeMissingSymbol(ray_query_symbol, native_diagnostic())
  }
}

///|
/// A bottom-level acceleration structure: triangle geometries.
pub struct Blas {
  raw : @c.OpaquePtr
}

///|
/// A top-level acceleration structure: instances of BLASes.
pub struct Tlas {
  raw : @c.OpaquePtr
}

///|
/// One triangle geometry of a BLAS: the most its builds hold.
/// `index_format_u32` 0 means no index buffer.
pub(all) struct BlasGeometry {
  vertex_format_u32 : UInt
  vertex_count : UInt
  index_format_u32 : UInt
  index_count : UInt
  opaque_ : Bool
}

///|
/// A BLAS for `geometries` (at least one). An error in the description reaches
/// the device's error scopes and gives an invalid BLAS, as wgpu's other
/// objects do.
pub fn Device::create_blas(
  self : Device,
  geometries : Array[BlasGeometry],
  flags? : UInt = ACCELERATION_STRUCTURE_PREFER_FAST_TRACE,
) -> Blas raise WgpuError {
  require_ray_query()
  let flat = FixedArray::make(geometries.length() * 5, 0U)
  for i, g in geometries {
    flat[i * 5] = g.vertex_format_u32
    flat[i * 5 + 1] = g.vertex_count
    flat[i * 5 + 2] = g.index_format_u32
    flat[i * 5 + 3] = g.index_count
    flat[i * 5 + 4] = if g.opaque_ { 1U } else { 0U }
  }
  let raw = @c.blas_create(self.raw, flat, geometries.length().to_uint64(), flags)
  if @c.opaque_ptr_is_null(raw) {
    raise WgpuNativeMissingSymbol(ray_query_symbol, "wgpuDeviceCreateBlasExt returned nothing (no geometry, or more than 1024)")
  }
  { raw, }
}

///|
/// A TLAS of at most `max_instances` instances.
pub fn Device::create_tlas(
  self : Device,
  max_instances : UInt,
  flags? : UInt = ACCELERATION_STRUCTURE_PREFER_FAST_TRACE,
) -> Tlas raise WgpuError {
  require_ray_query()
  let raw = @c.tlas_create(self.raw, max_instances, flags)
  if @c.opaque_ptr_is_null(raw) {
    raise WgpuNativeMissingSymbol("wgpuDeviceCreateTlasExt", native_diagnostic())
  }
  { raw, }
}

///|
pub fn Blas::release(self : Blas) -> Unit {
  @c.blas_release(self.raw)
}

///|
pub fn Tlas::release(self : Tlas) -> Unit {
  @c.tlas_release(self.raw)
}

///|
/// The buffers of one geometry in a build, in the BLAS's geometry order.
/// Vertex and index buffers need `BUFFER_USAGE_BLAS_INPUT`.
pub(all) struct BlasBuildGeometry {
  vertex_buffer : Buffer
  first_vertex : UInt
  vertex_stride : UInt64
  index_buffer : Buffer?
  first_index : UInt
}

///|
/// One TLAS instance: a BLAS, a row-major 3x4 transform (12 values), 24 bits
/// the shader reads back and an 8-bit visibility mask.
pub(all) struct TlasInstance {
  blas : Blas
  transform : FixedArray[Float]
  custom : UInt
  mask : UInt
}

///|
/// One command's builds: add BLASes with their geometry buffers and TLASes
/// with their instances, then `record` it into an encoder. A TLAS is built
/// after the BLASes its instances name, in the same build or an earlier one.
pub struct AccelerationStructureBuild {
  raw : @c.RayQueryBuild
}

///|
pub fn AccelerationStructureBuild::new() -> AccelerationStructureBuild raise WgpuError {
  require_ray_query()
  { raw: @c.rq_build_new() }
}

///|
pub fn AccelerationStructureBuild::blas(
  self : AccelerationStructureBuild,
  blas : Blas,
  geometries : Array[BlasBuildGeometry],
) -> Unit {
  @c.rq_build_blas(self.raw, blas.raw)
  for g in geometries {
    match g.index_buffer {
      Some(index) =>
        @c.rq_build_geometry(self.raw, g.vertex_buffer.raw, g.first_vertex, g.vertex_stride, index.raw, g.first_index)
      None => @c.rq_build_geometry_unindexed(self.raw, g.vertex_buffer.raw, g.first_vertex, g.vertex_stride)
    }
  }
}

///|
pub fn AccelerationStructureBuild::tlas(
  self : AccelerationStructureBuild,
  tlas : Tlas,
  instances : Array[TlasInstance],
) -> Unit raise WgpuError {
  @c.rq_build_tlas(self.raw, tlas.raw)
  for i in instances {
    if i.transform.length() != 12 {
      raise WgpuNativeMissingSymbol("TlasInstance", "a TLAS instance's transform is 12 values (row-major 3x4)")
    }
    @c.rq_build_instance(self.raw, i.blas.raw, i.transform, i.custom, i.mask)
  }
}

///|
/// Records the builds into `encoder`.
pub fn AccelerationStructureBuild::record(
  self : AccelerationStructureBuild,
  encoder : CommandEncoder,
) -> Unit raise WgpuError {
  if !@c.rq_build_record(encoder.raw, self.raw) {
    raise WgpuNativeMissingSymbol("wgpuCommandEncoderBuildAccelerationStructuresExt", native_diagnostic())
  }
}

///|
/// A `var name: acceleration_structure` binding of a bind group layout.
pub fn BindGroupLayoutBuilder::add_tlas(
  self : BindGroupLayoutBuilder,
  binding : UInt,
  visibility : ShaderStage,
  vertex_return? : Bool = false,
) -> Bool {
  @c.bind_group_layout_builder_add_tlas(self.raw, binding, visibility.raw, vertex_return)
}

///|
/// Binds `tlas` at `binding`.
pub fn BindGroupBuilder::add_tlas(self : BindGroupBuilder, binding : UInt, tlas : Tlas) -> Bool {
  @c.bind_group_builder_add_tlas(self.raw, binding, tlas.raw)
}
