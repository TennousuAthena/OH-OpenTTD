// Tests the helpers consumed by the real HarmonyOS GLES driver, without an SDK.
#include "../../src/video/harmonyos_render.h"

#include <iostream>
#include <stdexcept>

using HarmonyOSRender::DirtyRegions;
using HarmonyOSRender::PackRows;
using HarmonyOSRender::Rect;

static void Require(bool condition, const char *message)
{
	if (!condition) throw std::runtime_error(message);
}

static bool Contains(const Rect &r, int x, int y)
{
	return x >= r.x && y >= r.y && x < r.x + r.w && y < r.y + r.h;
}

static void TestDirtyRegions()
{
	DirtyRegions dirty;
	dirty.Reset(1000, 1000);
	dirty.Add(0, 0, 20, 20);
	dirty.Add(900, 900, 20, 20);
	Require(dirty.Get().size() == 2, "distant cursor/window changes must remain separate");
	dirty.Add(10, 10, 20, 20);
	Require(dirty.Get().size() == 2, "overlap should merge without merging a distant region");
	uint64_t area = 0;
	for (const auto &r : dirty.Get()) area += r.Area();
	Require(area == 1300, "overlapping region bounds are wrong");

	dirty.Clear();
	dirty.Add(-5, -7, 10, 12);
	Require(dirty.Get().size() == 1 && dirty.Get()[0].x == 0 && dirty.Get()[0].y == 0 && dirty.Get()[0].w == 5 && dirty.Get()[0].h == 5, "negative coordinates must clip safely");
	dirty.Add(std::numeric_limits<int>::max(), std::numeric_limits<int>::max(), std::numeric_limits<int>::max(), std::numeric_limits<int>::max());
	dirty.Add(-10, -10, -1, 2);
	Require(dirty.Get().size() == 1, "empty/overflowing out-of-screen changes should add nothing");

	dirty.Clear();
	for (size_t i = 0; i <= DirtyRegions::MAX_REGIONS; ++i) dirty.Add(static_cast<int>(i) * 30, 0, 10, 10);
	Require(dirty.Get().size() == 1 && dirty.Get()[0].Area() == 1000000, "region capacity overflow must preserve coverage using a full upload");
	dirty.Clear();
	dirty.Add(0, 0, 1000, 600);
	Require(dirty.Get().size() == 1 && dirty.Get()[0].Area() == 1000000, "60 percent coverage should collapse to a full upload");

	// A bridging merge must revisit earlier rectangles to preserve a disjoint list.
	dirty.Clear();
	dirty.Add(0, 0, 10, 10);
	dirty.Add(20, 0, 10, 10);
	dirty.Add(10, 0, 10, 10);
	Require(dirty.Get().size() == 1 && dirty.Get()[0].Area() == 300, "transitive merges should include all touching regions");

	// Verify every dirty pixel survives clipping/merging/capacity decisions.
	dirty.Reset(31, 23);
	std::array<bool, 31 * 23> expected{};
	for (int i = 0; i < 43; ++i) {
		int x = (i * 7) % 41 - 5;
		int y = (i * 11) % 33 - 5;
		int w = (i * 3) % 9 + 1;
		int h = (i * 5) % 7 + 1;
		dirty.Add(x, y, w, h);
		for (int py = 0; py < 23; ++py) for (int px = 0; px < 31; ++px) {
			if (Contains({x, y, w, h}, px, py)) expected[py * 31 + px] = true;
		}
		Require(dirty.Get().size() <= DirtyRegions::MAX_REGIONS, "dirty storage must remain bounded");
	}
	for (int py = 0; py < 23; ++py) for (int px = 0; px < 31; ++px) {
		if (!expected[py * 31 + px]) continue;
		Require(std::any_of(dirty.Get().begin(), dirty.Get().end(), [=](const Rect &r) { return Contains(r, px, py); }), "dirty pixel coverage was lost");
	}
	dirty.Reset(7, 3);
	Require(dirty.Get().empty(), "resize must discard obsolete dirty coordinates");
}

static void TestPacking(size_t bytes_per_pixel)
{
	// Odd pitch, clipped-width upload and three distinct rows exercise GLES2 packing.
	constexpr size_t pitch = 7, height = 4;
	std::vector<uint8_t> source(pitch * height * bytes_per_pixel);
	for (size_t i = 0; i < source.size(); ++i) source[i] = static_cast<uint8_t>(i * 19 + 11);
	std::vector<uint8_t> scratch;
	const Rect rect{2, 1, 3, 3};
	auto packed = PackRows(source, pitch, rect, bytes_per_pixel, scratch);
	Require(packed.size() == 9 * bytes_per_pixel, "packed byte count is incorrect");
	for (size_t y = 0; y < 3; ++y) for (size_t x = 0; x < 3 * bytes_per_pixel; ++x) {
		Require(packed[y * 3 * bytes_per_pixel + x] == source[((y + 1) * pitch + 2) * bytes_per_pixel + x], "row packing changed bytes or read row padding");
	}
	const auto *scratch_address = scratch.data();
	size_t scratch_capacity = scratch.capacity();
	PackRows(source, pitch, {3, 0, 2, 2}, bytes_per_pixel, scratch);
	PackRows(source, pitch, rect, bytes_per_pixel, scratch);
	Require(scratch.data() == scratch_address && scratch.capacity() == scratch_capacity, "alternating upload sizes should reuse scratch storage");

	auto full_width = PackRows(source, pitch, {0, 1, 7, 2}, bytes_per_pixel, scratch);
	Require(full_width.data() == source.data() + pitch * bytes_per_pixel && full_width.size() == 14 * bytes_per_pixel, "full-width upload should bypass CPU packing");
	auto single_row = PackRows(source, pitch, {2, 2, 3, 1}, bytes_per_pixel, scratch);
	Require(single_row.data() == source.data() + (2 * pitch + 2) * bytes_per_pixel, "single-row upload should bypass CPU packing");
	Require(PackRows(source, pitch, {-1, 0, 2, 2}, bytes_per_pixel, scratch).empty(), "negative source position should be rejected");
	Require(PackRows(source, pitch, {6, 0, 2, 2}, bytes_per_pixel, scratch).empty(), "rectangle wider than pitch should be rejected");
	Require(PackRows(source, pitch, {0, 3, 2, 2}, bytes_per_pixel, scratch).empty(), "rectangle below source allocation should be rejected");
	Require(PackRows(source, 0, rect, bytes_per_pixel, scratch).empty(), "zero pitch should be rejected");
	Require(PackRows(source, std::numeric_limits<size_t>::max(), rect, 4, scratch).empty(), "stride overflow should be rejected");
}

int main()
{
	try {
		TestDirtyRegions();
		TestPacking(1); // indexed pixels and 40bpp animation mask
		TestPacking(4); // packed BGRA framebuffer, copied without CPU channel conversion
		std::cout << "PASS: real GLES upload helpers (dirty coverage, clipping, capacity, odd strides, raw channels, reusable packing)\n";
	} catch (const std::exception &error) {
		std::cerr << "FAIL: " << error.what() << '\n';
		return 1;
	}
}
