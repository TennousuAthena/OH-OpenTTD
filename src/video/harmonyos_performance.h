/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License, version 2.
 * See COPYING.md for the license and warranty disclaimer.
 */

/** @file harmonyos_performance.h Bounded, optional native performance counters. */

#ifndef HARMONYOS_PERFORMANCE_H
#define HARMONYOS_PERFORMANCE_H

#include <array>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdio>

#if defined(OPENTTD_HARMONYOS_PERF)
extern void HarmonyOSLog(const char *level, const char *message);
#endif

namespace HarmonyOSPerformance {

enum class Stage : size_t { Input, InputQueue, Palette, Upload, Draw, Swap, Frame, Audio, MusicLock, Tick, PreInputWait, MusicRender, Count };

#if defined(OPENTTD_HARMONYOS_PERF)

/* 0.25 ms buckets through 32 ms, followed by progressively wider buckets.
 * Percentiles are upper bounds of these buckets, not exact sample percentiles. */
inline constexpr size_t FINE_BINS = 128;
inline constexpr size_t BIN_COUNT = FINE_BINS + 8;
inline constexpr uint64_t BIN_STEP_NS = 250000;

inline uint64_t Now()
{
	return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
		std::chrono::steady_clock::now().time_since_epoch()).count());
}

inline size_t BinFor(uint64_t duration)
{
	if (duration < FINE_BINS * BIN_STEP_NS) return static_cast<size_t>(duration / BIN_STEP_NS);
	uint64_t boundary = FINE_BINS * BIN_STEP_NS * 2;
	for (size_t bin = FINE_BINS; bin + 1 < BIN_COUNT; ++bin, boundary *= 2) {
		if (duration < boundary) return bin;
	}
	return BIN_COUNT - 1;
}

inline uint64_t BinUpperBound(size_t bin)
{
	return bin < FINE_BINS ? (bin + 1) * BIN_STEP_NS : (FINE_BINS * BIN_STEP_NS) << (bin - FINE_BINS + 1);
}

struct Counter {
	std::atomic<uint64_t> count{0};
	std::atomic<uint64_t> total_ns{0};
	std::atomic<uint64_t> max_ns{0};
	std::array<std::atomic<uint64_t>, BIN_COUNT> histogram{};
};

inline std::array<Counter, static_cast<size_t>(Stage::Count)> counters{};
inline std::atomic<uint64_t> uploaded_bytes{0};
inline std::atomic<uint64_t> coalesced_moves{0};
inline std::atomic<uint64_t> queue_high_water{0};
inline std::atomic<uint64_t> submitted_frames{0};

inline void SetMaximum(std::atomic<uint64_t> &maximum, uint64_t value)
{
	auto previous = maximum.load(std::memory_order_relaxed);
	while (previous < value && !maximum.compare_exchange_weak(previous, value, std::memory_order_relaxed)) {}
}

inline void Record(Stage stage, uint64_t duration)
{
	auto &counter = counters[static_cast<size_t>(stage)];
	counter.count.fetch_add(1, std::memory_order_relaxed);
	counter.total_ns.fetch_add(duration, std::memory_order_relaxed);
	counter.histogram[BinFor(duration)].fetch_add(1, std::memory_order_relaxed);
	SetMaximum(counter.max_ns, duration);
}

inline void AddUploadedBytes(size_t count) { uploaded_bytes.fetch_add(count, std::memory_order_relaxed); }
inline void AddCoalescedMoves(size_t count) { coalesced_moves.fetch_add(count, std::memory_order_relaxed); }
inline void SetQueueDepth(size_t count) { SetMaximum(queue_high_water, count); }

/* Called only on the EGL owner thread, after a successful swap. Successful
 * submissions are not proof of compositor presentation or input-to-photon time. */
inline void FrameSubmitted()
{
	static uint64_t previous = 0;
	const uint64_t now = Now();
	if (previous != 0) Record(Stage::Frame, now - previous);
	previous = now;
	submitted_frames.fetch_add(1, std::memory_order_relaxed);
}

/* Flush only on the render thread. Audio callbacks merely increment atomics:
 * no callback logging, dynamic allocation, or profiler mutex is required. */
inline void Flush()
{
	static uint64_t previous = Now();
	const uint64_t now = Now();
	if (now - previous < 1000000000) return;
	const double seconds = static_cast<double>(now - previous) / 1000000000.0;
	previous = now;
	char message[2048];
	int used = std::snprintf(message, sizeof(message),
		"harmonyos perf: submit_fps=%.1f upload_MiB_s=%.2f queue_max=%llu coalesced=%llu",
		submitted_frames.exchange(0, std::memory_order_relaxed) / seconds,
		uploaded_bytes.exchange(0, std::memory_order_relaxed) / (seconds * 1048576.0),
		static_cast<unsigned long long>(queue_high_water.exchange(0, std::memory_order_relaxed)),
		static_cast<unsigned long long>(coalesced_moves.exchange(0, std::memory_order_relaxed)));
	static constexpr std::array<const char *, static_cast<size_t>(Stage::Count)> names{
		"input", "queue_age", "palette", "upload", "gl_submit", "swap", "frame_interval",
		"audio", "music_lock", "tick", "pre_input_wait", "music_render"};
	for (size_t index = 0; index < counters.size(); ++index) {
		auto &counter = counters[index];
		const auto count = counter.count.exchange(0, std::memory_order_relaxed);
		const auto total = counter.total_ns.exchange(0, std::memory_order_relaxed);
		const auto maximum = counter.max_ns.exchange(0, std::memory_order_relaxed);
		std::array<uint64_t, BIN_COUNT> bins{};
		uint64_t samples = 0;
		for (size_t bin = 0; bin < bins.size(); ++bin) {
			bins[bin] = counter.histogram[bin].exchange(0, std::memory_order_relaxed);
			samples += bins[bin];
		}
		if (count == 0 || used < 0 || static_cast<size_t>(used) >= sizeof(message)) continue;
		uint64_t accumulated = 0;
		size_t percentile = 0;
		for (; percentile + 1 < bins.size(); ++percentile) {
			accumulated += bins[percentile];
			if (accumulated >= (samples * 95 + 99) / 100) break;
		}
		const int written = std::snprintf(message + used, sizeof(message) - used,
			" %s_ms=%.3f/%.3f/%.3f", names[index], static_cast<double>(total) / (count * 1000000.0),
			static_cast<double>(BinUpperBound(percentile)) / 1000000.0, static_cast<double>(maximum) / 1000000.0);
		if (written < 0) break;
		used += written;
	}
	HarmonyOSLog("info", message);
}

#else

inline uint64_t Now() { return 0; }
inline void Record(Stage, uint64_t) {}
inline void AddUploadedBytes(size_t) {}
inline void AddCoalescedMoves(size_t) {}
inline void SetQueueDepth(size_t) {}
inline void FrameSubmitted() {}
inline void Flush() {}

#endif

class Scope {
	Stage stage;
	uint64_t begin;
public:
	explicit Scope(Stage stage) : stage(stage), begin(Now()) {}
	~Scope() { Record(this->stage, Now() - this->begin); }
	Scope(const Scope &) = delete;
	Scope &operator=(const Scope &) = delete;
};

} // namespace HarmonyOSPerformance

#endif /* HARMONYOS_PERFORMANCE_H */
