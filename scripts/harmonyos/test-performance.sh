#!/usr/bin/env bash
# Exercise the production bounded profiler with concurrent input/audio writers.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openttd-perf.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/test.cpp" <<'CPP'
#include "harmonyos_performance.h"
#include <cassert>
#include <cstring>
#include <string>
#include <thread>
#include <vector>
static std::string output;
void HarmonyOSLog(const char *, const char *message) { output = message; }
int main()
{
	using namespace HarmonyOSPerformance;
#if defined(OPENTTD_HARMONYOS_PERF)
	assert(BinUpperBound(BinFor(16700000)) == 16750000);
	assert(BinFor(UINT64_MAX) == BIN_COUNT - 1);
	std::vector<std::thread> workers;
	for (unsigned i = 0; i < 4; ++i) workers.emplace_back([] {
		for (unsigned n = 0; n < 1000; ++n) {
			Record(Stage::Audio, 16700000);
			AddUploadedBytes(4);
			AddCoalescedMoves(1);
			SetQueueDepth(n);
		}
	});
	for (auto &worker : workers) worker.join();
	auto &counter = counters[static_cast<size_t>(Stage::Audio)];
	assert(counter.count == 4000);
	assert(counter.total_ns == 4000ULL * 16700000);
	assert(counter.histogram[BinFor(16700000)] == 4000);
	assert(counter.max_ns == 16700000);
	assert(uploaded_bytes == 16000 && coalesced_moves == 4000 && queue_high_water == 999);
	FrameSubmitted();
	FrameSubmitted();
	assert(submitted_frames == 2);
	Flush();
	assert(output.empty());
	std::this_thread::sleep_for(std::chrono::milliseconds(1010));
	Flush();
	assert(output.find("submit_fps=") != std::string::npos);
	assert(output.find("audio_ms=16.700/16.750/16.700") != std::string::npos);
	assert(counter.count == 0 && counter.total_ns == 0);
	assert(uploaded_bytes == 0 && coalesced_moves == 0 && queue_high_water == 0);
#else
	assert(Now() == 0);
	Record(Stage::Audio, 100);
	FrameSubmitted();
	Flush();
	assert(output.empty());
#endif
	std::puts("PASS production performance counters");
}
CPP
for mode in enabled disabled; do
  flags=(-DOPENTTD_HARMONYOS_PERF_DISABLED=1)
  [ "$mode" = disabled ] || flags=(-DOPENTTD_HARMONYOS_PERF=1)
  c++ -std=c++17 -O2 -Wall -Wextra -Werror -pthread "${flags[@]}" \
    -I"$REPO_ROOT/src/video" "$WORK_DIR/test.cpp" -o "$WORK_DIR/test-$mode"
  "$WORK_DIR/test-$mode"
done
