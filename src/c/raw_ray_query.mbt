// Ray-query externs (wgpu_stub_ray_query.c, and the TLAS bindings of the bind
// group builders in wgpu_stub_descs_pipelines.c). All entry points are
// optional symbols of the BlankMauser/wgpu-native fork; with a stock library
// they return NULL / false.

///|
pub extern "C" fn ray_query_available() -> Bool = "mbt_wgpu_ray_query_available"

///|
/// `geometries`: five values a geometry (vertex format, vertex count, index
/// format or 0, index count, opaque).
#borrow(device, geometries)
pub extern "C" fn blas_create(
  device : Device,
  geometries : FixedArray[UInt],
  count : UInt64,
  flags : UInt,
) -> OpaquePtr = "mbt_wgpu_blas_create"

///|
#borrow(device)
pub extern "C" fn tlas_create(device : Device, max_instances : UInt, flags : UInt) -> OpaquePtr = "mbt_wgpu_tlas_create"

///|
pub extern "C" fn blas_release(blas : OpaquePtr) -> Unit = "mbt_wgpu_blas_release"

///|
pub extern "C" fn tlas_release(tlas : OpaquePtr) -> Unit = "mbt_wgpu_tlas_release"

///|
#external
pub type RayQueryBuild

///|
pub extern "C" fn rq_build_new() -> RayQueryBuild = "mbt_wgpu_rq_build_new"

///|
#borrow(build)
pub extern "C" fn rq_build_blas(build : RayQueryBuild, blas : OpaquePtr) -> Unit = "mbt_wgpu_rq_build_blas"

///|
#borrow(build, vertex, index)
pub extern "C" fn rq_build_geometry(
  build : RayQueryBuild,
  vertex : Buffer,
  first_vertex : UInt,
  stride : UInt64,
  index : Buffer,
  first_index : UInt,
) -> Unit = "mbt_wgpu_rq_build_geometry"

///|
#borrow(build, vertex)
pub extern "C" fn rq_build_geometry_unindexed(
  build : RayQueryBuild,
  vertex : Buffer,
  first_vertex : UInt,
  stride : UInt64,
) -> Unit = "mbt_wgpu_rq_build_geometry_unindexed"

///|
#borrow(build)
pub extern "C" fn rq_build_tlas(build : RayQueryBuild, tlas : OpaquePtr) -> Unit = "mbt_wgpu_rq_build_tlas"

///|
#borrow(build, transform)
pub extern "C" fn rq_build_instance(
  build : RayQueryBuild,
  blas : OpaquePtr,
  transform : FixedArray[Float],
  custom : UInt,
  mask : UInt,
) -> Unit = "mbt_wgpu_rq_build_instance"

///|
#borrow(encoder, build)
pub extern "C" fn rq_build_record(encoder : CommandEncoder, build : RayQueryBuild) -> Bool = "mbt_wgpu_rq_build_record"

///|
#borrow(builder)
pub extern "C" fn bind_group_layout_builder_add_tlas(
  builder : BindGroupLayoutBuilderObj,
  binding : UInt,
  visibility : UInt64,
  vertex_return : Bool,
) -> Bool = "mbt_wgpu_bind_group_layout_builder_add_tlas"

///|
#borrow(builder)
pub extern "C" fn bind_group_builder_add_tlas(
  builder : BindGroupBuilderObj,
  binding : UInt,
  tlas : OpaquePtr,
) -> Bool = "mbt_wgpu_bind_group_builder_add_tlas"
