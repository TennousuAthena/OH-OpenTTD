/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file harmonyos_v.cpp Implementation of the HarmonyOS EGL/GLES video driver. */

#include "../stdafx.h"
#include "../openttd.h"
#include "../error_func.h"
#include "../gfx_func.h"
#include "../palette_func.h"
#include "../rev.h"
#include "../blitter/factory.hpp"
#include "../network/network.h"
#include "../thread.h"
#include "../progress.h"
#include "../core/geometry_func.hpp"
#include "../fileio_func.h"
#include "../framerate_type.h"
#include "../window_func.h"
#include "harmonyos_v.h"
#include "harmonyos_input.h"
#include "harmonyos_textinput.h"
#include "harmonyos_performance.h"
#include <mutex>

#ifdef HARMONYOS
#	include <EGL/egl.h>
#	include <EGL/eglext.h>
#	include <GLES3/gl3.h>
#	include <native_window/external_window.h>
#	include "lifecycle_bridge.h"
#endif

#include "../safeguards.h"

#ifdef HARMONYOS

static FVideoDriver_HarmonyOS iFVideoDriver_HarmonyOS;
static OHNativeWindow *_oh_native_window = nullptr;
static openttd::NativeWindowProvider _window_provider;
static std::mutex _native_window_mutex;
extern "C" bool OpenTTDHarmonyOSIsBackground();
extern "C" bool OpenTTDHarmonyOSShouldExit();
extern "C" void OpenTTDHarmonyOSPauseAudio();
extern "C" void OpenTTDHarmonyOSResumeAudio();

extern "C" __attribute__((visibility("default"))) void openttd_native_set_window(void *window, uint64_t width, uint64_t height)
{
	std::lock_guard<std::mutex> lock(_native_window_mutex);
	if (window == nullptr) return;
	OH_NativeWindow_NativeObjectReference(window);
	auto previous = _window_provider.snapshot();
	_window_provider.set(window, width, height);
	if (previous.window != nullptr) OH_NativeWindow_NativeObjectUnreference(previous.window);
}

extern "C" __attribute__((visibility("default"))) void openttd_native_clear_window()
{
	std::lock_guard<std::mutex> lock(_native_window_mutex);
	auto previous = _window_provider.snapshot();
	_window_provider.clear();
	if (previous.window != nullptr) OH_NativeWindow_NativeObjectUnreference(previous.window);
}

extern "C" __attribute__((visibility("default"))) void OpenTTDHarmonyOSSetNativeWindow(void *window, uint64_t width, uint64_t height)
{
	openttd_native_set_window(window, width, height);
}

extern "C" __attribute__((visibility("default"))) void OpenTTDHarmonyOSClearNativeWindow()
{
	openttd_native_clear_window();
}

static GLuint CompileShader(GLenum type, const char *source)
{
	GLuint shader = glCreateShader(type);
	if (shader == 0) {
		Debug(driver, 0, "harmonyos: glCreateShader({:#x}) failed, GL error {:#x}", type, glGetError());
		return 0;
	}
	glShaderSource(shader, 1, &source, nullptr);
	glCompileShader(shader);
	GLint success = GL_FALSE;
	glGetShaderiv(shader, GL_COMPILE_STATUS, &success);
	if (success == GL_TRUE) return shader;
	char log[1024]{};
	glGetShaderInfoLog(shader, sizeof(log), nullptr, log);
	Debug(driver, 0, "harmonyos: shader {} compilation failed, GL error {:#x}: {}", shader, glGetError(), log);
	glDeleteShader(shader);
	return 0;
}

std::optional<std::string_view> VideoDriver_HarmonyOS::Start(const StringList &parm)
{
	this->prefer_gles3 = GetDriverParamInt(parm, "gles", 3) != 2;
	auto window = _window_provider.snapshot();
	if (window.window == nullptr) return "harmonyos: native window is unavailable";
	if (!this->ChangeResolution(window.width, window.height)) return "harmonyos: unsupported framebuffer";
	CopyPalette(this->local_palette, true);
	if (!this->InitEGL()) {
		this->TeardownEGL();
		return "harmonyos: failed to initialise EGL/GLES";
	}
	return std::nullopt;
}

void VideoDriver_HarmonyOS::Stop()
{
	this->TeardownEGL();
	_screen.dst_ptr = nullptr;
	this->framebuffer.clear();
	this->animation_buffer.clear();
	this->upload_scratch.clear();
	this->realized_scratch.clear();
}

bool VideoDriver_HarmonyOS::InitEGL()
{
	{
		/* Retain the window while protected, then release the UI-side lock
		 * before the potentially slow EGL/shader initialisation. */
		std::lock_guard<std::mutex> lock(_native_window_mutex);
		auto window = _window_provider.snapshot();
		if (window.window == nullptr) return false;
		_oh_native_window = static_cast<OHNativeWindow *>(window.window);
		OH_NativeWindow_NativeObjectReference(_oh_native_window);
		this->surface_generation = window.generation;
	}

	this->egl_display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
	if (this->egl_display == EGL_NO_DISPLAY) return false;
	if (eglInitialize(this->egl_display, nullptr, nullptr) != EGL_TRUE) return false;
	if (eglBindAPI(EGL_OPENGL_ES_API) != EGL_TRUE) return false;

	for (int version : {3, 2}) {
		if (version == 3 && !this->prefer_gles3) continue;
		const EGLint attributes[] = {
			EGL_RENDERABLE_TYPE, version == 3 ? EGL_OPENGL_ES3_BIT_KHR : EGL_OPENGL_ES2_BIT,
			EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
			EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE,
		};
		EGLint count = 0;
		if (eglChooseConfig(this->egl_display, attributes, &this->egl_config, 1, &count) == EGL_TRUE && count != 0) {
			this->egl_surface = eglCreateWindowSurface(this->egl_display, this->egl_config, _oh_native_window, nullptr);
			if (this->egl_surface != EGL_NO_SURFACE && this->CreateGLContext(version)) {
				if (eglQuerySurface(this->egl_display, this->egl_surface, EGL_WIDTH, &this->surface_width) == EGL_TRUE &&
						eglQuerySurface(this->egl_display, this->egl_surface, EGL_HEIGHT, &this->surface_height) == EGL_TRUE &&
						this->surface_width > 0 && this->surface_height > 0) {
					this->egl_ok = true;
					this->ToggleVsync(_video_vsync);
					this->MakeDirty(0, 0, _screen.width, _screen.height);
					return true;
				}
			}
		}
		Debug(driver, 1, "harmonyos: GLES{} initialisation failed (EGL {:#x}), {}", version, eglGetError(), version == 3 ? "trying GLES2" : "no fallback available");
		if (this->egl_context != EGL_NO_CONTEXT) {
			if (eglGetCurrentContext() == this->egl_context) this->DeleteGLResources();
			eglMakeCurrent(this->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
			eglDestroyContext(this->egl_display, this->egl_context);
			this->egl_context = EGL_NO_CONTEXT;
		}
		if (this->egl_surface != EGL_NO_SURFACE) eglDestroySurface(this->egl_display, this->egl_surface);
		this->egl_surface = EGL_NO_SURFACE;
		this->max_texture_size = 0;
	}
	return false;
}

bool VideoDriver_HarmonyOS::CreateGLContext(int version)
{
	const EGLint attributes[] = {EGL_CONTEXT_CLIENT_VERSION, version, EGL_NONE};
	this->egl_context = eglCreateContext(this->egl_display, this->egl_config, EGL_NO_CONTEXT, attributes);
	if (this->egl_context == EGL_NO_CONTEXT) return false;
	if (eglMakeCurrent(this->egl_display, this->egl_surface, this->egl_surface, this->egl_context) != EGL_TRUE) return false;
	Debug(driver, 2, "harmonyos: EGL version={}, current context matches={}",
		eglQueryString(this->egl_display, EGL_VERSION), eglGetCurrentContext() == this->egl_context);
	this->gles3 = version == 3;
	const auto *gl_version = reinterpret_cast<const char *>(glGetString(GL_VERSION));
	const auto *glsl = reinterpret_cast<const char *>(glGetString(GL_SHADING_LANGUAGE_VERSION));
	const auto *renderer = reinterpret_cast<const char *>(glGetString(GL_RENDERER));
	Debug(driver, 1, "harmonyos: GL version={}, GLSL={}, renderer={}, error={:#x}",
		gl_version != nullptr ? gl_version : "unavailable", glsl != nullptr ? glsl : "unavailable",
		renderer != nullptr ? renderer : "unavailable", glGetError());
	glGetIntegerv(GL_MAX_TEXTURE_SIZE, &this->max_texture_size);
	if (std::max(_screen.width, _screen.height) > this->max_texture_size) return false;

	/* Upload Colour bytes unchanged. Both framebuffer and palette use the
	 * native packed Colour layout; presentation is always opaque. */
	GLint range[2]{}, precision = 0;
	glGetShaderPrecisionFormat(GL_FRAGMENT_SHADER, GL_HIGH_FLOAT, range, &precision);
	this->gpu_animation = precision >= 17 && range[1] >= 17;
	std::string vertex_source = HarmonyOSRender::VertexShader(this->gles3);
	std::string fragment_source = HarmonyOSRender::FragmentShader(this->gles3, std::endian::native == std::endian::little, this->gpu_animation);
	GLuint vertex = CompileShader(GL_VERTEX_SHADER, vertex_source.c_str());
	GLuint fragment = CompileShader(GL_FRAGMENT_SHADER, fragment_source.c_str());
	if (vertex == 0 || fragment == 0) {
		if (vertex != 0) glDeleteShader(vertex);
		if (fragment != 0) glDeleteShader(fragment);
		return false;
	}
	this->shader_program = glCreateProgram();
	glAttachShader(this->shader_program, vertex);
	glAttachShader(this->shader_program, fragment);
	glBindAttribLocation(this->shader_program, 0, "position");
	glBindAttribLocation(this->shader_program, 1, "texcoord");
	glLinkProgram(this->shader_program);
	glDeleteShader(vertex);
	glDeleteShader(fragment);
	GLint success = GL_FALSE;
	glGetProgramiv(this->shader_program, GL_LINK_STATUS, &success);
	if (success != GL_TRUE) {
		char log[1024]{};
		glGetProgramInfoLog(this->shader_program, sizeof(log), nullptr, log);
		Debug(driver, 0, "harmonyos: shader link failed: {}", log);
		return false;
	}
	glUseProgram(this->shader_program);
	glUniform1i(glGetUniformLocation(this->shader_program, "image"), 0);
	glUniform1i(glGetUniformLocation(this->shader_program, "palette"), 1);
	glUniform1i(glGetUniformLocation(this->shader_program, "animation"), 2);
	this->mode_uniform = glGetUniformLocation(this->shader_program, "mode");

	/* OpenTTD's first pixel is at the top left, whereas GL's origin is at the bottom. */
	static const GLfloat vertices[] = {
		-1.0f, -1.0f, 0.0f, 1.0f, 1.0f, -1.0f, 1.0f, 1.0f,
		-1.0f, 1.0f, 0.0f, 0.0f, 1.0f, 1.0f, 1.0f, 0.0f,
	};
	glGenBuffers(1, &this->vertex_buffer);
	glBindBuffer(GL_ARRAY_BUFFER, this->vertex_buffer);
	glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
	glGenTextures(1, &this->texture);
	glGenTextures(1, &this->palette_texture);
	glGenTextures(1, &this->animation_texture);
	for (GLuint texture : {this->texture, this->palette_texture, this->animation_texture}) {
		glBindTexture(GL_TEXTURE_2D, texture);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	}
	glBindTexture(GL_TEXTURE_2D, this->palette_texture);
	glTexImage2D(GL_TEXTURE_2D, 0, this->gles3 ? GL_RGBA8 : GL_RGBA, 256, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
	this->palette_dirty = true;
	return this->AllocateTextures();
}

bool VideoDriver_HarmonyOS::AllocateTextures()
{
	if (std::max(_screen.width, _screen.height) > this->max_texture_size) return false;
	glActiveTexture(GL_TEXTURE0);
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	if (this->gles3) glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
	glBindTexture(GL_TEXTURE_2D, this->texture);
	GLenum format = this->screen_depth == 8 ? (this->gles3 ? GL_RED : GL_LUMINANCE) : GL_RGBA;
	GLint internal = this->screen_depth == 8 ? (this->gles3 ? GL_R8 : GL_LUMINANCE) : (this->gles3 ? GL_RGBA8 : GL_RGBA);
	glTexImage2D(GL_TEXTURE_2D, 0, internal, _screen.width, _screen.height, 0, format, GL_UNSIGNED_BYTE, nullptr);
	glBindTexture(GL_TEXTURE_2D, this->animation_texture);
	uint8_t dummy = 0;
	bool anim = !this->animation_buffer.empty();
	glTexImage2D(GL_TEXTURE_2D, 0, this->gles3 ? GL_R8 : GL_LUMINANCE,
		anim ? _screen.width : 1, anim ? _screen.height : 1, 0, this->gles3 ? GL_RED : GL_LUMINANCE, GL_UNSIGNED_BYTE, anim ? nullptr : &dummy);
	if (glGetError() != GL_NO_ERROR) return false;
	this->textures_need_resize = false;
	this->MakeDirty(0, 0, _screen.width, _screen.height);
	Debug(driver, 1, "harmonyos: GLES{} {}x{}, blitter={}, palette animation={}, upload={}", this->gles3 ? 3 : 2,
		_screen.width, _screen.height, BlitterFactory::GetCurrentBlitter()->GetName(), anim ? (this->gpu_animation ? "GPU" : "CPU (insufficient highp)") : (this->screen_depth == 8 ? "GPU indexed" : "blitter"),
		this->gles3 ? "direct stride" : "reused row packing");
	return true;
}

void VideoDriver_HarmonyOS::DeleteGLResources()
{
	for (GLuint texture : {this->texture, this->palette_texture, this->animation_texture}) {
		if (texture != 0) glDeleteTextures(1, &texture);
	}
	if (this->vertex_buffer != 0) glDeleteBuffers(1, &this->vertex_buffer);
	if (this->shader_program != 0) glDeleteProgram(this->shader_program);
	this->texture = this->palette_texture = this->animation_texture = 0;
	this->shader_program = this->vertex_buffer = 0;
	this->mode_uniform = -1;
}

void VideoDriver_HarmonyOS::TeardownEGL()
{
	if (this->egl_display != EGL_NO_DISPLAY) {
		if (this->egl_context != EGL_NO_CONTEXT) {
			if (eglMakeCurrent(this->egl_display, this->egl_surface, this->egl_surface, this->egl_context) == EGL_TRUE) this->DeleteGLResources();
			eglMakeCurrent(this->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
			eglDestroyContext(this->egl_display, this->egl_context);
		}
		if (this->egl_surface != EGL_NO_SURFACE) eglDestroySurface(this->egl_display, this->egl_surface);
		eglTerminate(this->egl_display);
	}
	this->egl_display = EGL_NO_DISPLAY;
	this->egl_context = EGL_NO_CONTEXT;
	this->egl_surface = EGL_NO_SURFACE;
	this->texture = this->palette_texture = this->animation_texture = this->shader_program = this->vertex_buffer = 0;
	this->mode_uniform = -1;
	this->max_texture_size = 0;
	this->surface_width = this->surface_height = 0;
	this->egl_ok = false;
	this->uses_hardware_acceleration = false;
	this->textures_need_resize = this->palette_dirty = true;
	if (_oh_native_window != nullptr) {
		/* The XComponent owns the window; release only the reference we acquired. */
		OH_NativeWindow_NativeObjectUnreference(_oh_native_window);
		_oh_native_window = nullptr;
	}
}

bool VideoDriver_HarmonyOS::CheckSurface()
{
	auto window = _window_provider.snapshot();
	if (window.window == nullptr) {
		if (this->egl_display != EGL_NO_DISPLAY) this->TeardownEGL();
		return false;
	}
	if (!this->egl_ok || window.generation != this->surface_generation) {
		this->TeardownEGL();
		if (!this->InitEGL()) {
			this->TeardownEGL();
			return false;
		}
	}
	return true;
}

void VideoDriver_HarmonyOS::MakeDirty(int left, int top, int width, int height)
{
	this->dirty_regions.Add(left, top, width, height);
}

void VideoDriver_HarmonyOS::UploadPalette()
{
	if (!this->palette_dirty) return;
	glActiveTexture(GL_TEXTURE1);
	glBindTexture(GL_TEXTURE_2D, this->palette_texture);
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	if (this->gles3) glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
	/* At most 1 KiB, only when the palette changes. No bitmap expansion. */
	glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 256, 1, GL_RGBA, GL_UNSIGNED_BYTE, this->local_palette.palette);
	HarmonyOSPerformance::AddUploadedBytes(sizeof(this->local_palette.palette));
	this->palette_dirty = false;
}

void VideoDriver_HarmonyOS::UploadRegion(uint32_t texture, std::span<const uint8_t> source, const HarmonyOSRender::Rect &rect, size_t bytes_per_pixel)
{
	const uint8_t *data;
	if (this->gles3) {
		glPixelStorei(GL_UNPACK_ROW_LENGTH, _screen.pitch);
		data = source.data() + (static_cast<size_t>(rect.y) * _screen.pitch + rect.x) * bytes_per_pixel;
	} else {
		auto packed = HarmonyOSRender::PackRows(source, _screen.pitch, rect, bytes_per_pixel, this->upload_scratch);
		assert(!packed.empty());
		data = packed.data();
	}
	glBindTexture(GL_TEXTURE_2D, texture);
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	GLenum format = bytes_per_pixel == 1 ? (this->gles3 ? GL_RED : GL_LUMINANCE) : GL_RGBA;
	glTexSubImage2D(GL_TEXTURE_2D, 0, rect.x, rect.y, rect.w, rect.h, format, GL_UNSIGNED_BYTE, data);
	HarmonyOSPerformance::AddUploadedBytes(rect.Area() * bytes_per_pixel);
}

void VideoDriver_HarmonyOS::UploadTexture()
{
	glActiveTexture(GL_TEXTURE0);
	for (const auto &rect : this->dirty_regions.Get()) {
		if (!this->gpu_animation && !this->animation_buffer.empty()) {
			this->UploadRealizedRegion(rect);
		} else {
			this->UploadRegion(this->texture, this->framebuffer, rect, this->screen_depth / 8);
			if (!this->animation_buffer.empty()) this->UploadRegion(this->animation_texture, this->animation_buffer, rect, 1);
		}
	}
	if (this->gles3) glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
}

void VideoDriver_HarmonyOS::UploadRealizedRegion(const HarmonyOSRender::Rect &rect)
{
	/* GLES2 devices without enough highp cannot safely emulate byte arithmetic
	 * in the shader. Keep the encoded framebuffer intact and realize only the
	 * upload in reused storage, using the core's exact brightness function. */
	size_t pixels = static_cast<size_t>(rect.Area());
	if (this->realized_scratch.size() < pixels) this->realized_scratch.resize(pixels);
	const Colour *source = reinterpret_cast<const Colour *>(this->framebuffer.data());
	for (int y = 0; y < rect.h; ++y) for (int x = 0; x < rect.w; ++x) {
		size_t offset = static_cast<size_t>(rect.y + y) * _screen.pitch + rect.x + x;
		uint8_t index = this->animation_buffer[offset];
		this->realized_scratch[static_cast<size_t>(y) * rect.w + x] = index != 0 ?
			AdjustBrightness(this->local_palette.palette[index], GetColourBrightness(source[offset])) : source[offset];
	}
	glBindTexture(GL_TEXTURE_2D, this->texture);
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	if (this->gles3) glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
	glTexSubImage2D(GL_TEXTURE_2D, 0, rect.x, rect.y, rect.w, rect.h, GL_RGBA, GL_UNSIGNED_BYTE, this->realized_scratch.data());
	HarmonyOSPerformance::AddUploadedBytes(pixels * sizeof(Colour));
}

void VideoDriver_HarmonyOS::DrawFullscreenQuad()
{
	glViewport(0, 0, this->surface_width, this->surface_height);
	glDisable(GL_BLEND);
	glUseProgram(this->shader_program);
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, this->texture);
	glActiveTexture(GL_TEXTURE1);
	glBindTexture(GL_TEXTURE_2D, this->palette_texture);
	glActiveTexture(GL_TEXTURE2);
	glBindTexture(GL_TEXTURE_2D, this->animation_texture);
	glUniform1i(this->mode_uniform, this->screen_depth == 8 ? 1 : (this->animation_buffer.empty() || !this->gpu_animation ? 0 : 2));
	glBindBuffer(GL_ARRAY_BUFFER, this->vertex_buffer);
	glEnableVertexAttribArray(0);
	glEnableVertexAttribArray(1);
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), nullptr);
	glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), reinterpret_cast<const void *>(2 * sizeof(GLfloat)));
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

void VideoDriver_HarmonyOS::Paint()
{
	if (this->background) return;
	PerformanceMeasurer framerate(PFE_VIDEO);
	if (!this->CheckSurface()) return;
	if (this->textures_need_resize && !this->AllocateTextures()) {
		Debug(driver, 1, "harmonyos: texture allocation failed; recreating EGL");
		this->TeardownEGL();
		return;
	}
	{
		HarmonyOSPerformance::Scope timing(HarmonyOSPerformance::Stage::Upload);
		this->UploadPalette();
		this->UploadTexture();
	}
	{
		HarmonyOSPerformance::Scope timing(HarmonyOSPerformance::Stage::Draw);
		this->DrawFullscreenQuad();
	}
	GLenum error = glGetError();
	if (error != GL_NO_ERROR) {
		Debug(driver, 1, "harmonyos: frame GL error {:#x}; recreating EGL", error);
		this->TeardownEGL();
		return;
	}
	EGLBoolean swapped;
	{
		HarmonyOSPerformance::Scope timing(HarmonyOSPerformance::Stage::Swap);
		swapped = eglSwapBuffers(this->egl_display, this->egl_surface);
	}
	if (swapped != EGL_TRUE) {
		Debug(driver, 1, "harmonyos: swap failed: {:#x}", eglGetError());
		this->TeardownEGL();
		return;
	}
	HarmonyOSPerformance::FrameSubmitted();
	this->dirty_regions.Clear();
}

void VideoDriver_HarmonyOS::CheckPaletteAnim()
{
	HarmonyOSPerformance::Scope timing(HarmonyOSPerformance::Stage::Palette);
	if (!CopyPalette(this->local_palette)) return;
	this->palette_dirty = true;
	Blitter *blitter = BlitterFactory::GetCurrentBlitter();
	if (blitter->UsePaletteAnimation() == Blitter::PaletteAnimation::Blitter) blitter->PaletteAnimate(this->local_palette);
	if (!this->gpu_animation && !this->animation_buffer.empty()) this->MakeDirty(0, 0, _screen.width, _screen.height);
	/* Indexed and 40bpp modes change only the small GPU palette. */
}

void VideoDriver_HarmonyOS::MainLoop()
{
	this->StartGameThread();
	while (!_exit_game) {
		{
			HarmonyOSPerformance::Scope timing(HarmonyOSPerformance::Stage::Tick);
			this->Tick();
		}
		HarmonyOSPerformance::Flush();
		this->SleepTillNextTick();
		if (this->background || !_window_provider.valid()) std::this_thread::sleep_for(std::chrono::milliseconds(100));
	}
	this->StopGameThread();
}

bool VideoDriver_HarmonyOS::ChangeResolution(int w, int h)
{
	if (w <= 0 || h <= 0 || w > UINT16_MAX / 2 || h > UINT16_MAX / 2) return false;
	Blitter *blitter = BlitterFactory::GetCurrentBlitter();
	uint8_t depth = blitter->GetScreenDepth();
	if (depth != 8 && depth != 32) return false;
	if (this->max_texture_size != 0 && std::max(w, h) > this->max_texture_size) return false;
	this->screen_depth = depth;
	size_t pixels = static_cast<size_t>(w) * h;
	this->framebuffer.assign(pixels * depth / 8, 0);
	this->animation_buffer.assign(blitter->NeedsAnimationBuffer() ? pixels : 0, 0);
	_screen.width = _screen.pitch = w;
	_screen.height = h;
	_screen.dst_ptr = this->framebuffer.data();
	_cur_resolution = Dimension(w, h);
	this->textures_need_resize = true;
	this->dirty_regions.Reset(w, h);
	CopyPalette(this->local_palette, true);
	this->palette_dirty = true;
	blitter->PostResize();
	GameSizeChanged();
	this->MakeDirty(0, 0, w, h);
	return true;
}

bool VideoDriver_HarmonyOS::AfterBlitterChange()
{
	return this->ChangeResolution(_screen.width, _screen.height);
}

bool VideoDriver_HarmonyOS::ToggleFullscreen(bool fullscreen)
{
	_fullscreen = fullscreen;
	return true;
}

void VideoDriver_HarmonyOS::ToggleVsync(bool vsync)
{
	this->uses_hardware_acceleration = false;
	if (!this->egl_ok || this->background) return;
	if (eglSwapInterval(this->egl_display, vsync ? 1 : 0) == EGL_TRUE) {
		/* The common loop skips its timer only when vsync is requested and
		 * this flag is set. With swap interval 0 the refresh timer paces it. */
		this->uses_hardware_acceleration = true;
	} else {
		Debug(driver, 1, "harmonyos: cannot set swap interval {}: {:#x}; using refresh timer", vsync ? 1 : 0, eglGetError());
		eglSwapInterval(this->egl_display, 0);
	}
}

bool VideoDriver_HarmonyOS::LockVideoBuffer()
{
	this->before_input = HarmonyOSPerformance::Now();
	return false;
}

bool VideoDriver_HarmonyOS::PollEvent()
{
	HarmonyOSPerformance::Record(HarmonyOSPerformance::Stage::PreInputWait, HarmonyOSPerformance::Now() - this->before_input);
	/* This runs under the game's state lock. UI callbacks only set atomics. */
	if (OpenTTDHarmonyOSShouldExit()) _exit_game = true;
	bool background = OpenTTDHarmonyOSIsBackground();
	if (background != this->background) {
		this->background = background;
		if (background) {
			this->already_paused = _pause_mode.Test(PauseMode::Normal);
			_pause_mode.Set(PauseMode::Normal);
			HarmonyOSResetInputState();
			OpenTTDHarmonyOSPauseAudio();
			this->uses_hardware_acceleration = false;
		} else {
			if (!this->already_paused) _pause_mode.Reset(PauseMode::Normal);
			OpenTTDHarmonyOSResumeAudio();
			this->ToggleVsync(_video_vsync);
		}
	}
	auto window = _window_provider.snapshot();
	if (window.window != nullptr && (window.width != static_cast<uint64_t>(_screen.width) || window.height != static_cast<uint64_t>(_screen.height))) {
		this->ChangeResolution(window.width, window.height);
	}
	HarmonyOSInputDrain();
	HarmonyOSUpdateTextInputState();
	this->fast_forward_key_pressed = HarmonyOSInputFastForwardHeld();
	return false;
}

void VideoDriver_HarmonyOS::EditBoxLostFocus()
{
	HarmonyOSCancelTextComposition();
}

#endif /* HARMONYOS */
