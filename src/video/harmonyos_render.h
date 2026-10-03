/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 */

/** @file harmonyos_render.h Host-testable dirty-region and texture-upload helpers. */

#ifndef VIDEO_HARMONYOS_RENDER_H
#define VIDEO_HARMONYOS_RENDER_H

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <span>
#include <string>
#include <vector>

namespace HarmonyOSRender {

/** Shader sources shared by the native driver and offscreen GPU regressions. */
inline std::string VertexShader(bool gles3)
{
	std::string source = gles3 ? "#version 300 es\nin vec2 position; in vec2 texcoord; out vec2 uv;" :
		"attribute vec2 position; attribute vec2 texcoord; varying vec2 uv;";
	return source + "void main() { uv = texcoord; gl_Position = vec4(position, 0.0, 1.0); }";
}

inline std::string FragmentShader(bool gles3, bool little_endian, bool gpu_animation)
{
	std::string source = gles3 ? "#version 300 es\n" : "";
	source += "#ifdef GL_FRAGMENT_PRECISION_HIGH\nprecision highp float;\n#else\nprecision mediump float;\n#endif\n";
	source += gles3 ? "in vec2 uv; out vec4 output_colour;\n#define SAMPLE texture\n#define OUTPUT output_colour\n" :
		"varying vec2 uv;\n#define SAMPLE texture2D\n#define OUTPUT gl_FragColor\n";
	source += "uniform sampler2D image; uniform sampler2D palette; uniform sampler2D animation; uniform int mode;";
	source += little_endian ? "vec3 unpack_colour(vec4 c) { return c.bgr; }" : "vec3 unpack_colour(vec4 c) { return c.gba; }";
	source +=
		"vec3 lookup_palette(float index) {"
		"  float entry = floor(index * 255.0 + 0.5);"
		"  return unpack_colour(SAMPLE(palette, vec2((entry + 0.5) / 256.0, 0.5)));"
		"}";
	if (gpu_animation) {
		/* Reproduce ReallyAdjustBrightness byte arithmetic, including its
		 * zero-brightness sentinel, integer floors and saturated channels.
		 * Highp is checked by the driver before enabling this program path. */
		source +=
			"vec3 adjust_brightness(vec3 colour, float brightness) {"
			"  float value = floor(brightness * 255.0 + 0.5);"
			"  if (value == 0.0) value = 128.0;"
			"  vec3 bytes = floor(colour * 255.0 + 0.5);"
			"  vec3 adj = floor(bytes * value / 128.0);"
			"  vec3 overflow = max(adj - 255.0, 0.0);"
			"  float ob = floor((overflow.r + overflow.g + overflow.b) / 2.0);"
			"  vec3 result = min(vec3(255.0), adj + floor(ob * max(255.0 - adj, 0.0) / 256.0));"
			"  return result / 255.0;"
			"}";
	}
	source +=
		"void main() {"
		"  vec4 raw = SAMPLE(image, uv);"
		"  vec3 colour = unpack_colour(raw);"
		"  if (mode == 1) { colour = lookup_palette(raw.r); }";
	if (gpu_animation) {
		source +=
			"  else if (mode == 2) {"
			"    float index = SAMPLE(animation, uv).r;"
			"    if (index > 0.0) colour = adjust_brightness(lookup_palette(index), max(max(colour.r, colour.g), colour.b));"
			"  }";
	}
	return source + "  OUTPUT = vec4(colour, 1.0); }";
}

struct Rect {
	int x, y, w, h;

	uint64_t Area() const { return static_cast<uint64_t>(this->w) * this->h; }
};

/** Keep disconnected changes separate, with bounded storage and upload calls. */
class DirtyRegions {
public:
	static constexpr size_t MAX_REGIONS = 16;

	void Reset(int width, int height)
	{
		this->width = width;
		this->height = height;
		this->Clear();
	}

	void Clear() { this->count = 0; }
	std::span<const Rect> Get() const { return {this->regions.data(), this->count}; }

	void Add(int left, int top, int width, int height)
	{
		/* Widen before adding: untrusted/out-of-bounds input must not overflow. */
		int right = static_cast<int>(std::clamp<int64_t>(static_cast<int64_t>(left) + width, 0, this->width));
		int bottom = static_cast<int>(std::clamp<int64_t>(static_cast<int64_t>(top) + height, 0, this->height));
		left = std::clamp(left, 0, this->width);
		top = std::clamp(top, 0, this->height);
		if (right <= left || bottom <= top) return;
		Rect next{left, top, right - left, bottom - top};

		/* A merge can intersect an earlier region, so restart after merging. */
		for (size_t i = 0; i < this->count;) {
			const auto &r = this->regions[i];
			if (next.x <= r.x + r.w && r.x <= next.x + next.w &&
					next.y <= r.y + r.h && r.y <= next.y + next.h) {
				right = std::max(next.x + next.w, r.x + r.w);
				bottom = std::max(next.y + next.h, r.y + r.h);
				next.x = std::min(next.x, r.x);
				next.y = std::min(next.y, r.y);
				next.w = right - next.x;
				next.h = bottom - next.y;
				this->regions[i] = this->regions[--this->count];
				i = 0;
			} else {
				++i;
			}
		}

		if (this->count == MAX_REGIONS) {
			this->Full();
			return;
		}
		this->regions[this->count++] = next;
		uint64_t area = 0;
		for (const auto &r : this->Get()) area += r.Area();
		/* Above 60% coverage one full upload is cheaper than many small ones. */
		if (area * 5 >= static_cast<uint64_t>(this->width) * this->height * 3) this->Full();
	}

private:
	void Full()
	{
		this->regions[0] = {0, 0, this->width, this->height};
		this->count = 1;
	}

	std::array<Rect, MAX_REGIONS> regions{};
	size_t count = 0;
	int width = 0, height = 0;
};

/**
 * Return a contiguous subrectangle for GLES2, reusing scratch storage.
 * Full-width regions and single rows can be uploaded without a CPU copy.
 * Source bytes keep their original channel order; the shader interprets them.
 */
inline std::span<const uint8_t> PackRows(std::span<const uint8_t> source, size_t pitch, const Rect &rect, size_t bytes_per_pixel, std::vector<uint8_t> &scratch)
{
	if (rect.x < 0 || rect.y < 0 || rect.w <= 0 || rect.h <= 0 || bytes_per_pixel == 0 || pitch == 0) return {};
	if (static_cast<size_t>(rect.x) + rect.w > pitch || pitch > std::numeric_limits<size_t>::max() / bytes_per_pixel) return {};
	size_t stride = pitch * bytes_per_pixel;
	size_t first_row = static_cast<size_t>(rect.y);
	size_t last_row = first_row + rect.h - 1;
	if (last_row >= source.size() / stride) return {};
	size_t row_bytes = static_cast<size_t>(rect.w) * bytes_per_pixel;
	if (static_cast<size_t>(rect.h) > std::numeric_limits<size_t>::max() / row_bytes) return {};
	size_t size = row_bytes * rect.h;
	const uint8_t *begin = source.data() + first_row * stride + static_cast<size_t>(rect.x) * bytes_per_pixel;
	if (static_cast<size_t>(rect.w) == pitch || rect.h == 1) return {begin, size};
	if (scratch.size() < size) scratch.resize(size);
	for (int y = 0; y < rect.h; ++y) std::copy_n(begin + static_cast<size_t>(y) * stride, row_bytes, scratch.data() + static_cast<size_t>(y) * row_bytes);
	return {scratch.data(), size};
}

} // namespace HarmonyOSRender

#endif /* VIDEO_HARMONYOS_RENDER_H */
