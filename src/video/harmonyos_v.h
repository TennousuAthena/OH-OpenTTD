/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file harmonyos_v.h Base of the HarmonyOS EGL/GLES video driver. */

#ifndef VIDEO_HARMONYOS_V_H
#define VIDEO_HARMONYOS_V_H

#include "../video/video_driver.hpp"
#include "../gfx_func.h"
#include "harmonyos_render.h"

#ifdef HARMONYOS
#	include <EGL/egl.h>
#	include <EGL/eglext.h>
#	include <GLES3/gl3.h>
#endif

/** The HarmonyOS video driver, using GLES3 with a GLES2 fallback. */
class VideoDriver_HarmonyOS : public VideoDriver {
public:
	VideoDriver_HarmonyOS() : VideoDriver(false) {}

	std::optional<std::string_view> Start(const StringList &parm) override;
	void Stop() override;
	void MainLoop() override;
	void MakeDirty(int left, int top, int width, int height) override;
	bool ChangeResolution(int w, int h) override;
	bool ToggleFullscreen(bool fullscreen) override;
	void ToggleVsync(bool vsync) override;
	bool PollEvent() override;
	bool AfterBlitterChange() override;
	void EditBoxLostFocus() override;
	bool HasEfficient8Bpp() const override { return true; }
	bool HasAnimBuffer() override { return true; }
	uint8_t *GetAnimBuffer() override { return this->animation_buffer.empty() ? nullptr : this->animation_buffer.data(); }

	std::string_view GetName() const override { return "HarmonyOS"; }

protected:
	void Paint() override;
	void CheckPaletteAnim() override;
	bool LockVideoBuffer() override;

private:
	bool InitEGL();
	void TeardownEGL();
	bool CreateGLContext(int version);
	bool AllocateTextures();
	void DeleteGLResources();
	void UploadPalette();
	void UploadTexture();
	void UploadRealizedRegion(const HarmonyOSRender::Rect &rect);
	void UploadRegion(uint32_t texture, std::span<const uint8_t> source, const HarmonyOSRender::Rect &rect, size_t bytes_per_pixel);
	void DrawFullscreenQuad();
	bool CheckSurface();

#ifdef HARMONYOS
	EGLDisplay egl_display = EGL_NO_DISPLAY; ///< EGL display connection.
	EGLContext egl_context = EGL_NO_CONTEXT; ///< GLES rendering context.
	EGLSurface egl_surface = EGL_NO_SURFACE; ///< Current window surface.
	EGLConfig egl_config = nullptr; ///< Chosen framebuffer configuration.
#endif

	uint32_t texture = 0; ///< OpenGL texture holding the framebuffer.
	uint32_t palette_texture = 0; ///< 256-by-1 palette; GLES has no 1D textures.
	uint32_t animation_texture = 0; ///< Palette indices for the 40bpp blitter.
	uint32_t shader_program = 0; ///< Textured-quad program with palette/remap support.
	uint32_t vertex_buffer = 0; ///< Fullscreen quad vertex buffer.
	int mode_uniform = -1; ///< Cached rendering-mode uniform.
	HarmonyOSRender::DirtyRegions dirty_regions; ///< Bounded dirty-region list.
	uint64_t surface_generation = 0; ///< Bound native-window generation.
	bool egl_ok = false; ///< Whether EGL has been successfully initialised.
	bool gles3 = false; ///< Whether GLES3 row-stride and R8 uploads are available.
	bool gpu_animation = true; ///< Highp supports exact palette brightness arithmetic.
	bool prefer_gles3 = true; ///< Driver parameter can force the GLES2 fallback.
	bool textures_need_resize = true; ///< Reallocate GPU images after a blitter/size change.
	bool palette_dirty = true; ///< Retry palette upload after surface loss.
	int surface_width = 0, surface_height = 0; ///< Cached EGL drawable dimensions.
	int max_texture_size = 0; ///< Maximum supported width/height, queried once per context.
	bool background = false;
	bool already_paused = false; ///< Preserve the user's pause state across backgrounding.
	uint8_t screen_depth = 0; ///< Depth of the active OpenTTD blitter.
	Palette local_palette{}; ///< Palette copied under the game's palette lock.
	std::vector<uint8_t> framebuffer; ///< Backing store for the active blitter.
	std::vector<uint8_t> animation_buffer; ///< CPU palette indices for 40bpp-anim.
	std::vector<uint8_t> upload_scratch; ///< Reused contiguous subrectangle for GLES2.
	std::vector<Colour> realized_scratch; ///< CPU fallback for old GPUs without sufficient highp.
	uint64_t before_input = 0; ///< Optional profiler time before state/queue waits.
};

/** Factory for the HarmonyOS video driver. */
class FVideoDriver_HarmonyOS : public DriverFactoryBase {
public:
	FVideoDriver_HarmonyOS() : DriverFactoryBase(Driver::DT_VIDEO, 10, "harmonyos", "HarmonyOS EGL Video Driver") {}
	/* virtual */ std::unique_ptr<Driver> CreateInstance() const override { return std::make_unique<VideoDriver_HarmonyOS>(); }

	/* This mandatory platform driver must remain selectable when the optional
	 * hardware-driver setting is disabled. Its instance independently reports
	 * successful EGL pacing to the common draw scheduler. */
};

#endif /* VIDEO_HARMONYOS_V_H */
