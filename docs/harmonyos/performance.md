# HarmonyOS native performance

Debug and Release now build the native host and game engine with effective
`-O2 -g`. Debug signing remains available, and unstripped ELF symbols are kept
for debugging. The SDK's earlier Debug `-O0` flag is overridden by the final
target option. `OPENTTD_HARMONYOS_OPTIMIZE=OFF` or `--unoptimized-debug` is a
deliberate Debug-only baseline; it is rejected for Release.

## Build and verify

From the repository root, with the SDK, host tools and runtime dependencies
already prepared:

```bash
bash scripts/harmonyos/build-target.sh arm64-v8a Debug --perf
bash scripts/harmonyos/build-target.sh x86_64 Debug --perf
bash scripts/harmonyos/package.sh Debug --perf
```

`--perf` enables `OPENTTD_HARMONYOS_PERF=ON` for bounded native counters. Normal
builds default to PERF off and `driver=1` startup diagnostics.
`--verbose-native` enables the older verbose driver/input diagnostics; leave
it off when comparing performance.

For a local diagnostic HAP using the existing staged assets and signing
configuration, run from `harmonyos/`:

```bash
env DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
  DEVECO_HOME=/Applications/DevEco-Studio.app/Contents/tools \
  NODE_HOME=/Applications/DevEco-Studio.app/Contents/tools/node \
  OPENTTD_HARMONYOS_OPTIMIZE=ON OPENTTD_HARMONYOS_PERF=ON \
  OPENTTD_HARMONYOS_VERBOSE_LOG=OFF \
  /Applications/DevEco-Studio.app/Contents/tools/node/bin/node \
  hvigor/hvigor-wrapper.js assembleHap --mode module \
  -p module=entry@default -p product=default -p buildMode=debug \
  -p requiredDeviceType=2in1 --parallel --no-daemon --no-incremental
```

After assembly, run from the repository root:

```bash
python3 scripts/harmonyos/inspect-native-artifacts.py \
  --hap harmonyos/entry/build/default/outputs/default/entry-default-signed.hap \
  --native-build-root harmonyos/entry/.cxx/default/default/debug \
  --symbols-dir build/harmonyos/performance/symbols \
  --output build/harmonyos/performance/native-build-manifest.json
```

The inspector verifies both ABIs, effective runtime compiler flags, retained
debug symbols, matching packaged/engine/unstripped Build IDs, and the optimized
engine capability marker. It rejects the old scaffold. For a deliberately
unoptimized Debug comparison, add `--allow-unoptimized`.

These diagnostic artifacts stay local. Building or installing them does not
publish an AppGallery release. The existing `package.sh` source archive uses
committed `HEAD`; it does not include current uncommitted edits.

## Read the measurements

HiLog emits `harmonyos perf:` summaries approximately once per second from the
render thread. `submit_fps` counts successful `eglSwapBuffers` submissions;
it does not establish compositor-presented FPS or pointer-to-photon latency.
`upload_MiB_s` measures requested texture upload bytes, `queue_max` is the input
queue high-water mark, and `coalesced` counts merged movement events.

Each `<stage>_ms=mean/p95/max` value is slash-separated. The middle value is the
95th-percentile histogram bucket upper bound, using 0.25 ms buckets below
32 ms and wider buckets afterward. The last bucket saturates at 8192 ms;
use `max` to identify longer stalls. Concurrent audio samples can straddle
summary windows, so short-window averages are approximate.

Stages cover input draining, input queue age, waiting before input, palette
updates, texture upload, GL submission, buffer swap, frame intervals, render
ticks, audio callbacks, music-lock waiting, and music synthesis. Timings for GL
calls measure CPU submission/blocking time, not GPU execution time.

Select settled summary windows and export comparable JSON records:

```bash
python3 scripts/harmonyos/summarize-performance.py LOG --year 2026 \
  --start 20:16:45 --end 20:17:25 \
  --exclude '20:17:00..20:17:02.999' --output SUMMARY.json
python3 scripts/harmonyos/summarize-performance.py --self-test
```

Bounds include the summary's log timestamp and use the device clock. Time-only
bounds use the first log date; use full ISO dates across midnight. Each window
contributes equally to the reported mean because sample counts and exact
window durations are not logged. Stage p95 median/max values describe the
individual window bucket bounds; combining them cannot yield a pooled p95.

Use the in-game Help → Frame rate window or console `fps` alongside these
records. Simulation normally targets a 30 ms tick, approximately 33.33 ticks/s;
`gui.refresh_rate` defaults to 60 for drawing. The console's drawing
`expected: 33.33fps` comes from an upstream fixed expectation and does not prove
the configured graphics limit is 33.33 FPS.

## Physical-device comparison

- Use the same save, viewport, window size, zoom, pause state, music state,
  display refresh rate and power mode before and after a change.
- Record settled paused and running views separately, then mouse movement,
  viewport panning, dragging, resize/fullscreen, and music on/off.
- Exclude startup/loading and the first window after background/resume. The
  first resumed frame interval includes the pause between submissions.
- Validate frame pacing and visible pointer response on the device. Keep
  screenshots/traces and ELF Build IDs with results; submission counters alone
  cannot establish presentation quality.

## Measured device results, 2026-10-03

The arm64 MateBook HAD-W32 used the restored Dedston save dated 1952-05-09,
the same viewport, music enabled at volume 50, a 3120 × 2010 game surface,
and a 3120 × 2080 display. Startup and loading were excluded. The running
CPU profile started 53 seconds after unpausing. These results include the
compiler, upload, GPU palette/animation, pacing and input changes together;
they do not isolate the contribution of each change.

| Measurement | Existing Debug build | Optimized diagnostic build |
| --- | --- | --- |
| Paused console drawing rate, snapshot | 35.07 FPS | 60.00 FPS |
| Running console drawing rate, snapshot | 1.64 FPS | No comparable snapshot retained |
| Running EGL submissions, 15 log windows during CPU profile | Counter unavailable | Mean 60.02 FPS, range 59.9–60.2 |
| Paused RenderService buffer presentations | 59.68795/s | 59.99861/s |
| Running RenderService buffer presentations | 34.19650/s | 59.99866/s |
| Paused presentation interval p95 / max | 16.769 / 49.990 ms | 16.796 / 17.006 ms |
| Running presentation interval p95 / max | 209.045 / 266.776 ms | 16.845 / 17.463 ms |

Each RenderService capture contains 384 buffer presentation records and 383
intervals; p95 is the exact nearest-rank percentile of those intervals. These
are presentation timestamps for this application's surface, not evidence of
unique changed game frames or end-to-end pointer latency. Console snapshots,
EGL submission counters and presentation cadence measure different parts of
the pipeline. The baseline running SmartPerf layer lookup failed and its
zero readings were excluded.

Matched 15-second CPU captures had no lost samples. In the existing running
build, temporary byte-vector construction/destruction in `UploadTexture`
accounted for approximately 69.5% of cycle-weighted samples. That hotspot is
absent afterward; `UploadTexture` accounts for approximately 3.84% of the
optimized capture. These percentages describe sample shares, not CPU
utilization or isolated speedups.

- A smooth pointer trace requested approximately 143 movement events/s. The
  OS may merge delivery. Five measured windows averaged 60.02 submissions/s,
  merged five movements, and had input queue-age window p95 bounds no higher
  than 16.5 ms. This measures queued event age, not pointer-to-photon latency.
- Dragging retained button ordering, with zero merged movements in six
  windows. Queue-age window p95 median was 14.5 ms, maximum 14.75 ms.
- Six seconds of viewport panning forced full uploads. Five settled windows
  averaged 59.98 submissions/s at 1793.88 MiB/s, approximately 1.8 GiB/s;
  frame-interval window p95 bounds stayed at or below 19.5 ms.
- Forced GLES2 displayed the restored scene successfully. Window resizing
  between 2090 × 1324 and 3120 × 2010 exercised the row-packing path.
- The original music player's stop/start controls were tested with 13 settled
  windows each. Both states averaged 60.008 submissions/s. Audio callback
  means were 0.010 ms stopped and 1.867 ms playing; pre-input waiting means
  were 0.00185 ms and 0.00108 ms respectively. Synthesizer controls still
  synchronize, while status polling reads only the atomic snapshot. These
  short windows do not establish an isolated music-lock speedup. Summaries
  are `music-off-summary.json` and `music-on-summary.json`; music was restored
  to playing afterward.
- Forced `8bpp-optimized` with `support8bpp=yes` used GPU indexed colours;
  the restored scene's colours and text were checked at 3120 × 2010.
- With indexed GLES3 and VSync enabled at startup, the 15 settled windows
  from 20:35:24 to 20:35:39 averaged 120.01 submissions/s, range 119.8–120.2.
  The resize at 20:35:22 was excluded. Later submissions varied between
  approximately 60 and 120 as device pacing changed; this does not establish
  a constant 120 FPS or 120 presented frames/s. Hardware pacing avoids adding
  a second 60 FPS timer. Startup VSync on/off and the resume hook were checked;
  coverage of interactive settings-toggle sequences remains limited.
- After restoring the original VSync-off, `support8bpp=no`, automatic
  blitter/video-driver settings, the default GLES3 `40bpp-anim` GPU path
  displayed the paused baseline scene at 3120 × 2010. `final-fps.jpeg` records
  drawing and video output at 60.00 FPS. Background windows at 20:41 had zero
  submissions and no audio callback records. After foregrounding, settled
  logs from 20:41:52 show approximately 60 submissions/s and resumed audio
  callbacks without GL errors. The first resumed interval was excluded.

`indexed-vsync-summary.json`, `compat-live.log`, `indexed.jpeg` and
`final-fps.jpeg` retain these compatibility/lifecycle checks. The original
baseline save and a separate end-of-session save backup were preserved, and
the paused 1952-05-09 scene was restored.

Evidence stays in `build/harmonyos/performance/`,
`performance-baseline/`, `performance-baseline-running/`,
`performance-after/` and `performance-after-running/` under `build/harmonyos`.
Keep the logs, summaries, screenshots, profiles and measurement notes together.
`native-build-manifest.json` verifies effective `-O2 -g`, retained DWARF and
matching HAP/engine/symbol Build IDs for arm64-v8a and x86_64. Only arm64 was
run on physical hardware.

Host validation passed actual GLES2/GLES3 shader output comparisons against
the CPU pixel oracle, odd-width/unaligned cursor backup checks under ASan and
UBSan, input/upload/profiler tests, and lifecycle bridge tests including TSan.
This benchmark covers one save and short interaction tests; heavy endgame
saves and prolonged construction sessions still need separate measurements.
