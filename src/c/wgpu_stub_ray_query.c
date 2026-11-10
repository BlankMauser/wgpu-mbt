// Acceleration structures for ray queries (BlankMauser/wgpu-native fork,
// ffi/wgpu_ray_query.h): BLAS and TLAS creation, one build command, release.
// TLAS bindings of bind groups and layouts are in wgpu_stub_descs_pipelines.c
// (the builders live there).
//
// Every entry point is an optional symbol, like the Vulkan interop's: absent
// in a stock wgpu-native, the calls return NULL / 0 and the MoonBit side
// raises WgpuNativeMissingSymbol.

#include "wgpu_stub.h"
#include "wgpu_optional_sym.h"

#include <stdlib.h>
#include <string.h>

// Layouts must match wgpu_ray_query.h in the wgpu-native fork.
typedef struct mbt_WGPUBlasTriangleGeometryExt {
  WGPUVertexFormat vertexFormat;
  uint32_t vertexCount;
  WGPUIndexFormat indexFormat;
  uint32_t indexCount;
  WGPUBool opaque;
} mbt_WGPUBlasTriangleGeometryExt;

typedef struct mbt_WGPUBlasBuildGeometryExt {
  WGPUBuffer vertexBuffer;
  uint32_t firstVertex;
  uint64_t vertexStride;
  WGPUBuffer indexBuffer;
  uint32_t firstIndex;
} mbt_WGPUBlasBuildGeometryExt;

typedef struct mbt_WGPUBlasBuildExt {
  void *blas;
  const mbt_WGPUBlasBuildGeometryExt *geometries;
  size_t geometryCount;
} mbt_WGPUBlasBuildExt;

typedef struct mbt_WGPUTlasInstanceExt {
  void *blas;
  float transform[12];
  uint32_t custom;
  uint32_t mask;
} mbt_WGPUTlasInstanceExt;

typedef struct mbt_WGPUTlasBuildExt {
  void *tlas;
  const mbt_WGPUTlasInstanceExt *instances;
  size_t instanceCount;
} mbt_WGPUTlasBuildExt;

typedef void *(*pfn_create_blas)(WGPUDevice, const mbt_WGPUBlasTriangleGeometryExt *, size_t, uint32_t,
                                 WGPUStringView);
typedef void *(*pfn_create_tlas)(WGPUDevice, uint32_t, uint32_t, WGPUStringView);
typedef void (*pfn_release)(void *);
typedef void (*pfn_build)(WGPUCommandEncoder, const mbt_WGPUBlasBuildExt *, size_t, const mbt_WGPUTlasBuildExt *,
                          size_t);

static const char *const MBT_RQ_SYMS[] = {
    "wgpuDeviceCreateBlasExt",
    "wgpuDeviceCreateTlasExt",
    "wgpuBlasReleaseExt",
    "wgpuTlasReleaseExt",
    "wgpuCommandEncoderBuildAccelerationStructuresExt",
    "wgpuDeviceCreateBindGroupLayoutTlasExt",
    "wgpuDeviceCreateBindGroupTlasExt",
};

int32_t mbt_wgpu_ray_query_available(void) {
  for (size_t i = 0; i < sizeof(MBT_RQ_SYMS) / sizeof(MBT_RQ_SYMS[0]); i++) {
    if (!mbt_wgpu_optional_sym(MBT_RQ_SYMS[i])) return 0;
  }
  return 1;
}

// `geometries`: five u32 a geometry (vertex format, vertex count, index
// format or 0, index count, opaque).
void *mbt_wgpu_blas_create(WGPUDevice device, const uint32_t *geometries, uint64_t count, uint32_t flags) {
  pfn_create_blas f = (pfn_create_blas)mbt_wgpu_optional_sym(MBT_RQ_SYMS[0]);
  if (!f || !device || count == 0u || count > 1024u) return NULL;
  mbt_WGPUBlasTriangleGeometryExt *g =
      (mbt_WGPUBlasTriangleGeometryExt *)calloc((size_t)count, sizeof(mbt_WGPUBlasTriangleGeometryExt));
  if (!g) return NULL;
  for (uint64_t i = 0; i < count; i++) {
    g[i].vertexFormat = (WGPUVertexFormat)geometries[i * 5u];
    g[i].vertexCount = geometries[i * 5u + 1u];
    g[i].indexFormat = (WGPUIndexFormat)geometries[i * 5u + 2u];
    g[i].indexCount = geometries[i * 5u + 3u];
    g[i].opaque = geometries[i * 5u + 4u] ? 1u : 0u;
  }
  void *out = f(device, g, (size_t)count, flags, (WGPUStringView){NULL, 0});
  free(g);
  return out;
}

void *mbt_wgpu_tlas_create(WGPUDevice device, uint32_t max_instances, uint32_t flags) {
  pfn_create_tlas f = (pfn_create_tlas)mbt_wgpu_optional_sym(MBT_RQ_SYMS[1]);
  if (!f || !device) return NULL;
  return f(device, max_instances, flags, (WGPUStringView){NULL, 0});
}

void mbt_wgpu_blas_release(void *blas) {
  pfn_release f = (pfn_release)mbt_wgpu_optional_sym(MBT_RQ_SYMS[2]);
  if (f && blas) f(blas);
}

void mbt_wgpu_tlas_release(void *tlas) {
  pfn_release f = (pfn_release)mbt_wgpu_optional_sym(MBT_RQ_SYMS[3]);
  if (f && tlas) f(tlas);
}

// One build command, filled call by call (no struct crosses from MoonBit).
typedef struct mbt_rq_build {
  mbt_WGPUBlasBuildExt *blas;
  size_t blas_len, blas_cap;
  mbt_WGPUBlasBuildGeometryExt *geometries;
  size_t geometry_len, geometry_cap;
  // Geometries of each BLAS build: offset into `geometries` (pointers are set at record).
  size_t *geometry_first;
  mbt_WGPUTlasBuildExt *tlas;
  size_t tlas_len, tlas_cap;
  mbt_WGPUTlasInstanceExt *instances;
  size_t instance_len, instance_cap;
  size_t *instance_first;
  int failed;
} mbt_rq_build;

static void mbt_rq_build_drop(mbt_rq_build *b) {
  free(b->blas);
  free(b->geometries);
  free(b->geometry_first);
  free(b->tlas);
  free(b->instances);
  free(b->instance_first);
  memset(b, 0, sizeof(*b));
}

static void mbt_rq_build_finalize(void *self) { mbt_rq_build_drop((mbt_rq_build *)self); }

void *mbt_wgpu_rq_build_new(void) {
  mbt_rq_build *b = (mbt_rq_build *)moonbit_make_external_object(mbt_rq_build_finalize, sizeof(mbt_rq_build));
  if (b) memset(b, 0, sizeof(*b));
  return b;
}

static int mbt_rq_grow(void **items, size_t *cap, size_t len, size_t size) {
  if (len < *cap) return 1;
  size_t next = *cap ? *cap * 2u : 8u;
  void *p = realloc(*items, next * size);
  if (!p) return 0;
  *items = p;
  *cap = next;
  return 1;
}

void mbt_wgpu_rq_build_blas(void *build, void *blas) {
  mbt_rq_build *b = (mbt_rq_build *)build;
  if (!b || !blas) return;
  size_t cap = b->blas_cap;
  if (!mbt_rq_grow((void **)&b->blas, &b->blas_cap, b->blas_len, sizeof(*b->blas)) ||
      !mbt_rq_grow((void **)&b->geometry_first, &cap, b->blas_len, sizeof(size_t))) {
    b->failed = 1;
    return;
  }
  b->blas[b->blas_len] = (mbt_WGPUBlasBuildExt){blas, NULL, 0};
  b->geometry_first[b->blas_len] = b->geometry_len;
  b->blas_len++;
}

// A geometry of the BLAS build added last. `index` NULL: no index buffer.
void mbt_wgpu_rq_build_geometry(void *build, WGPUBuffer vertex, uint32_t first_vertex, uint64_t stride,
                                WGPUBuffer index, uint32_t first_index) {
  mbt_rq_build *b = (mbt_rq_build *)build;
  if (!b || b->blas_len == 0u || !vertex) return;
  if (!mbt_rq_grow((void **)&b->geometries, &b->geometry_cap, b->geometry_len, sizeof(*b->geometries))) {
    b->failed = 1;
    return;
  }
  b->geometries[b->geometry_len++] = (mbt_WGPUBlasBuildGeometryExt){vertex, first_vertex, stride, index, first_index};
  b->blas[b->blas_len - 1u].geometryCount++;
}

void mbt_wgpu_rq_build_geometry_unindexed(void *build, WGPUBuffer vertex, uint32_t first_vertex, uint64_t stride) {
  mbt_wgpu_rq_build_geometry(build, vertex, first_vertex, stride, NULL, 0u);
}

void mbt_wgpu_rq_build_tlas(void *build, void *tlas) {
  mbt_rq_build *b = (mbt_rq_build *)build;
  if (!b || !tlas) return;
  size_t cap = b->tlas_cap;
  if (!mbt_rq_grow((void **)&b->tlas, &b->tlas_cap, b->tlas_len, sizeof(*b->tlas)) ||
      !mbt_rq_grow((void **)&b->instance_first, &cap, b->tlas_len, sizeof(size_t))) {
    b->failed = 1;
    return;
  }
  b->tlas[b->tlas_len] = (mbt_WGPUTlasBuildExt){tlas, NULL, 0};
  b->instance_first[b->tlas_len] = b->instance_len;
  b->tlas_len++;
}

// An instance of the TLAS build added last: 12 floats (row-major 3x4).
void mbt_wgpu_rq_build_instance(void *build, void *blas, const float *transform, uint32_t custom, uint32_t mask) {
  mbt_rq_build *b = (mbt_rq_build *)build;
  if (!b || b->tlas_len == 0u) return;
  if (!mbt_rq_grow((void **)&b->instances, &b->instance_cap, b->instance_len, sizeof(*b->instances))) {
    b->failed = 1;
    return;
  }
  mbt_WGPUTlasInstanceExt *i = &b->instances[b->instance_len++];
  i->blas = blas;
  memcpy(i->transform, transform, sizeof(i->transform));
  i->custom = custom;
  i->mask = mask;
  b->tlas[b->tlas_len - 1u].instanceCount++;
}

// Records the command; 0 when the symbol is missing or an allocation failed.
int32_t mbt_wgpu_rq_build_record(WGPUCommandEncoder encoder, void *build) {
  pfn_build f = (pfn_build)mbt_wgpu_optional_sym(MBT_RQ_SYMS[4]);
  mbt_rq_build *b = (mbt_rq_build *)build;
  if (!f || !encoder || !b || b->failed) return 0;
  for (size_t i = 0; i < b->blas_len; i++) b->blas[i].geometries = b->geometries + b->geometry_first[i];
  for (size_t i = 0; i < b->tlas_len; i++) b->tlas[i].instances = b->instances + b->instance_first[i];
  f(encoder, b->blas, b->blas_len, b->tlas, b->tlas_len);
  return 1;
}
