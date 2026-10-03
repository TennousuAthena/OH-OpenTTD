# HarmonyOS Render Contract — `_screen` ↔ NativeWindow Framebuffer

This is the legacy **CPU presenter oracle** contract. The current production
driver in `src/video/harmonyos_v.cpp` uses EGL/GLES3 with a GLES2 fallback,
indexed/32-bpp framebuffer textures, and GPU palette/remap processing. Its
behavior is not limited by the CPU-only, 32-bpp oracle rules below. See
[the performance guide](performance.md) for the current presentation path's
diagnostics and physical-device validation.

The remaining sections define how the legacy presenter oracle presents the
software-rendered game buffer (`_screen`) through the CPU
path of the NdkNativeWindow buffer queue. It fixes the **pixel format**,
**stride/pitch relationship**, **dirty-rectangle semantics**, **RGBA/BGRA
conversion**, **fence handling**, **DPI scaling** and **surface generation**
so that a software presenter can be written once, host-tested, and dropped
into the XComponent surface holder without guessing.

The contract is enforced by `scripts/harmonyos/test-render-contract.sh`
(host-side, no device required) against the fixtures under
`scripts/harmonyos/test-fixtures/render/`.

## Scope and hard rules

1. **The oracle is debug-only and never ships to users.** The CPU presenter
   (`OH_NativeWindow` request/map/flush on the game buffer) is a bring-up
   oracle and the source of golden screenshots. It MUST be compiled behind
   the explicit diagnostic option `OPENTTD_HARMONYOS_RENDER_ORACLE` (CMake
   `-DOPENTTD_HARMONYOS_RENDER_ORACLE=ON`, or the equivalent
   `-DOPENTTD_HARMONYOS_RENDER_ORACLE` define on the host test). A build
   that does not opt into the oracle MUST NOT contain the presenter code
   path; the host test asserts the oracle is absent when the flag is off.
2. **OpenTTD draws through `DrawPixelInfo _screen`.** `src/gfx_func.h:64`.
   `_screen.dst_ptr` is the first pixel, `_screen.pitch` is the **number of
   pixels (not bytes)** per scanline, `_screen.width`/`_screen.height` are the
   visible dimensions. This mirrors `src/video/sdl2_v.cpp`/`sdl2_default_v.cpp`
   (`_screen.pitch = _sdl_surface->pitch / (bpp / 8)`).
3. **The presenter never modifies `_screen`.** It reads the OpenTTD buffer
   through the `VideoDriver` dirty-rectangle interface
   (`src/video/video_driver.hpp:42-49`, `MakeDirty(left, top, width, height)`)
   and copies dirty pixels into the NativeWindow buffer. `_screen` remains
   owned by the blitter (`src/blitter/base.hpp:40-47`, `BlitterParams` use
   `dst_pitch` in **bytes**).
4. **Only 32-bpp software rendering is contractually supported on the
   presenter path.** `Blitter_32bppBase::GetScreenDepth() == 32`
   (`src/blitter/32bpp_base.hpp:20`). 8-bpp paletted modes are out of scope
   for the CPU presenter (the palette-animation path is handled by the
   blitter, never by a per-frame palette upload over the buffer queue).

## Pixel format

OpenTTD's 32-bpp `Colour` type resolves per endianness
(`src/gfx_type.h:240-242`):

```cpp
using Colour = std::conditional_t<std::endian::native == std::endian::little,
                                  ColourBGRA, ColourARGB>;
```

`ColourBGRA` (`src/gfx_type.h:214-235`) lays channels **in memory** as
`b, g, r, a` (byte order BGRA on little-endian). HarmonyOS devices are
little-endian (arm64 / x86_64), so `_screen` pixels are **BGRA in memory**.

| Surface format (`OH_NativeBuffer_Format`) | Memory byte order | `_screen` (`ColourBGRA`) | Conversion needed |
|-------------------------------------------|-------------------|--------------------------|-------------------|
| `NATIVEBUFFER_PIXEL_FMT_BGRA_8888`        | `B G R A`         | `b g r a`                | **none (direct copy)** |
| `NATIVEBUFFER_PIXEL_FMT_RGBA_8888`        | `R G B A`         | `b g r a`                | swap R↔B during copy |
| `NATIVEBUFFER_PIXEL_FMT_RGBX_8888`        | `R G B X`         | `b g r a`                | swap R↔B, drop alpha |

Rule: **prefer `BGRA_8888`.** It is the byte-identical path and avoids a
per-pixel transform on the hot copy. `RGBA_8888`/`RGBX_8888` are supported
for surfaces that cannot allocate BGRA and MUST swap the red and blue
channels, preserving alpha as-is (never blend).

Exact enum values (from NDK `native_buffer/buffer_common.h`): `RGBA_8888 =
12`, `BGRA_8888 = 20`.

## Stride and pitch

Two different "stride" values exist and MUST NOT be confused:

- OpenTTD `_screen.pitch` — **pixels** per line (blitter convention,
  `src/blitter/base.hpp:46` uses `pitch` that can hold any pitch).
- NativeWindow `BufferHandle.stride` — **bytes** per line
  (`buffer_handle.h`, `int32_t stride; /* the stride of memory */`).

Contract:

```
stride_bytes  >= _screen.width * 4            (BufferHandle.stride)
_screen.pitch == stride_bytes / 4             only if (stride_bytes % 4 == 0)
line_offset(y) = y * stride_bytes             (bytes)
pixel(x,y)     = dst_ptr + y * stride_bytes + x * 4
```

The presenter MUST respect `BufferHandle.stride`, including when it is
**larger than** `width * 4` (padding, alignment, or a deliberately odd
stride). Copying `width * 4` bytes per line starting at `line_offset(y)` is
the correct write; it never touches the pad bytes. When the engine driver
sets `_screen.pitch`, it MUST derive it from `stride_bytes / 4`
(**floor division**); if `stride_bytes % 4 != 0` the presenter MUST refuse
the surface (`NATIVE_ERROR_INVALID_ARGUMENTS`) rather than misalign pixels.

## Dirty rectangles

OpenTTD calls `VideoDriver::MakeDirty(left, top, width, height)` for every
change (`src/video/video_driver.hpp:42-49`). The SDL default backend unions
the rectangles (`src/video/sdl2_v.cpp:28-35`):

```cpp
void VideoDriver_SDL_Base::MakeDirty(int left, int top, int width, int height)
{
	Rect r = {left, top, left + width, top + height};
	this->dirty_rect = BoundingRect(this->dirty_rect, r);
}
```

Contract:

1. **Union semantics.** Consecutive `MakeDirty` calls before a present are
   merged into one bounding `Rect` (`left, top, right, bottom` half-open),
   exactly like `BoundingRect`. The presenter presents the union region.
2. **Empty rect = no flush.** If the union is empty
   (`right <= left || bottom <= top`), `Paint`/present returns without
   calling the buffer queue. (Matches `IsEmptyRect` in
   `sdl2_default_v.cpp:95`.)
3. **Clipping.** Dirty rectangles MAY extend beyond the surface (resize
   races, palette animation marking the whole old screen). Before presenting,
   the region must be clipped to `[0, width) × [0, height)`; out-of-bounds
   pixels are never copied. A fully-outside rect produces an empty clip →
   no flush.
4. **Region passed to flush.** `Region` (NDK `external_window.h`): `struct
   Rect { int32_t x; int32_t y; uint32_t w; uint32_t h; }`;
   `rectNumber == 1`; `rects == &clip`. If the clip is empty, pass
   `rects == nullptr, rectNumber == 0` (fill entire buffer dirty size) —
   only allowed when the whole surface is dirty, and only as an optimization.

## Fence handling

`OH_NativeWindow_NativeWindowRequestBuffer` returns a `fenceFd` (acquire
fence). Rules (mirroring `NativeRender.cpp` request/map/flush):

1. On `RequestBuffer`, record `fenceFd` **before** touching
   `BufferHandle.virAddr`.
2. If `fenceFd > 0`, wait on the fence (poll/`sync_wait` on device; a no-op
   on the host oracle which returns `fenceFd = 0` deterministically). Writing
   pixels before the fence signals is undefined behaviour.
3. `OH_NativeWindow_NativeWindowFlushBuffer(window, buffer, fenceFd, region)`
   — the SAME `fenceFd` returned by the request is passed back; the system
   closes it. The producer must never `close()` the acquire fence itself,
   and must never flush a fence value it did not receive from a request.
4. A buffer is either flushed or it stays requested; the request MUST always
   be paired with exactly one flush (or the buffer slot is exhausted).
   `fenceFd = -1` on request means "no fence" (the host oracle uses 0 for
   "no fence" and models the close semantics).

## DPI

`_screen.width/height` are logical game pixels. The XComponent surface is in
physical pixels and may have a different size than `_screen` (device scale
`densityPixels` > 1). Contract:

```
surface_w = round(_screen.width  * densityPixels)
surface_h = round(_screen.height * densityPixels)
```

- The buffer is allocated at **surface size**; stride comes from the buffer.
- The presenter copies `_screen` pixels into the surface buffer. When
  `densityPixels == 1` and surface == screen, the copy is 1:1 and the dirty
  rect maps unchanged.
- When `densityPixels > 1`, the CPU presenter upscales with **nearest
  neighbour** (blocky is correct for the oracle; true scaling is a later
  GPU-driven story). Dirty rects are scaled by `floor(x * scale)` /
  `ceil((x + w) * scale)` so a scale-plus-copy covers at least the dirty
  area.
- DPI value is read once per surface generation from the XComponent
  `density` field; `densityPixels = density / 160.0` (dots per inch).

## Surface generation

The XComponent surface is recreated (`onSurfaceCreated`) whenever the
surface identity changes; generation numbering follows the lifecycle
contract (Todo 8: monotonic, bumped on recreate, 0 = none). Contract:

1. Each present is tagged with the **surface generation** the `_screen`
   buffer was rendered for.
2. The presenter caches the generation it last flushed to the queue.
3. Presenting a frame whose generation is **older than** the current cached
   generation, or presenting generation 0 (never created), MUST be rejected
   WITHOUT flushing — a stale buffer would show a torn old frame. Rejection
   is a typed `STALE_GENERATION` result, never a crash.
4. A **zero-sized surface** (`surface_w <= 0 || surface_h <= 0`) also
   rejects without flushing (`INVALID_SURFACE`).
5. After a generation bump (recreate), any in-flight requested-but-not-
   flushed buffer from the old generation is treated as stale; one more
   flush attempt returns `STALE_GENERATION` and the loop restarts from a
   fresh request.

## The oracle (`OPENTTD_HARMONYOS_RENDER_ORACLE`)

The host test embeds a **pure C++ software oracle** that models the
`OH_NativeWindow` queue on the host:

- `RequestBuffer` allocates a `BufferHandle` with
  `{ fd=-1, width, stride, height, size, format, virAddr, ... }`, returns
  `fenceFd = 0`.
- `FlushBuffer(window, buffer, fenceFd, region)` records the flushed region,
  closes the modeled fence, and exposes the buffer bytes for the test to
  hash (screenshot).
- `Present` copies the `_screen` dirty region with the stride/clipping/format
  rules above.

The oracle renders **deterministic color bars and/or a checkerboard** into
`_screen`-shaped fixtures so the screenshots have a stable hash. The test
asserts:

- exact stride handling including **odd stride** (`stride % 4 != 0` must be
  rejected by the driver adaptation layer; `stride` larger than needed is
  handled),
- clipping never reads/writes out of bounds,
- dirty-union == `BoundingRect`,
- RGBA↔BGRA conversion round-trips (swap R↔B twice == identity),
- stale generation and zero-sized surface reject WITHOUT flush,
- screenshot hash/tolerance per scenario (golden values computed by the same
  deterministic renderer, cross-checked with the host `shasum`).

## Blitter reuse / references

| Concern | Reference |
|---------|-----------|
| `_screen` (DrawPixelInfo) | `src/gfx_type.h:157-162`, `src/gfx_func.h:64` |
| `MakeDirty` interface | `src/video/video_driver.hpp:42-49` |
| dirty-union + Paint | `src/video/sdl2_v.cpp:28-35`, `sdl2_default_v.cpp:91-127` |
| `_screen.pitch` in pixels | `sdl2_default_v.cpp:160-163` |
| `Colour` per-endian | `src/gfx_type.h:165-242` |
| blitter 32bpp depth / params | `src/blitter/32bpp_base.hpp:20`, `src/blitter/base.hpp:40-47` |
| `BufferHandle` (stride/bytes) | NDK `native_window/buffer_handle.h` |
| request/map/flush + fences | NDK `native_window/external_window.h` (`RequestBuffer`/`FlushBuffer`/`Region`) |
| pixel formats | NDK `native_buffer/buffer_common.h` (`OH_NativeBuffer_Format`) |
