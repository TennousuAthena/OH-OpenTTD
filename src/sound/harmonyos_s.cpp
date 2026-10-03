/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file harmonyos_s.cpp Playing sound via the HarmonyOS OHAudio renderer. */

#ifdef WITH_HARMONYOS

#include "../stdafx.h"

#include "../debug.h"
#include "../mixer.h"
#include "sound_driver.hpp"
#include "../video/harmonyos_performance.h"

#include <atomic>
#include <optional>
#include <string_view>
#include <ohaudio/native_audiostream_base.h>
#include <ohaudio/native_audiorenderer.h>
#include <ohaudio/native_audiostreambuilder.h>

#include "../safeguards.h"

/**
 * Sound driver for HarmonyOS, implemented on top of the OHAudio C renderer
 * API (libohaudio.so).
 *
 * Design notes:
 *  - Callback-driven: OHAudio calls the write-data callback on its own audio
 *    thread; we hand every callback buffer straight to MxMixSamples, which
 *    writes interleaved 2-channel signed 16-bit PCM (the exact native S16LE
 *    stereo layout OHAudio is configured with).
 *  - Format: S16LE stereo (CH_LAYOUT_STEREO), RAW encoding, 48 kHz preferred
 *    with a negotiated fallback through the common rates. MxInitialize() is
 *    called with the rate OHAudio actually negotiated.
 *  - Focus/interruption: handled via the interrupt callback. DUCK/MUTE lower
 *    the renderer volume, PAUSE/STOP are acknowledged (the system owns the
 *    pause), RESUME/UNDUCK/UNMUTE restart/restore.
 *  - Underruns: surfaced through the OS underflow counter (and a local
 *    callback-size guard) for the 30-minute device audio test.
 *  - Background pause / renderer recreation: PauseOutput() is meant to be
 *    driven when the app goes to the background; ResumeOutput() restarts the
 *    stream, recreating the renderer with the last negotiated rate if an
 *    error callback tore it down.
 *
 * The OpenTTD decoded-PCM/music pipeline is untouched: sounds and music are
 * decoded by the existing soundloaders/decoders and mixed by MxMixSamples,
 * just like every other OpenTTD sound driver.
 */
class SoundDriver_HarmonyOS : public SoundDriver {
public:
	SoundDriver_HarmonyOS() = default;
	std::optional<std::string_view> Start(const StringList &param) override;

	void Stop() override;

	/** Called once every game tick; not needed by the callback-driven driver. */
	void MainLoop() override;

	std::string_view GetName() const override { return "harmonyos"; }

	/** Pause the output (app going to background). */
	void PauseOutput();

	/** Resume the output after a background pause or interrupt resume. */
	void ResumeOutput();

	/** Number of OS-reported underflows since the renderer started. */
	uint32_t GetUnderflowCount() const;

private:
	/** Not copyable. */
	SoundDriver_HarmonyOS(const SoundDriver_HarmonyOS &) = delete;
	SoundDriver_HarmonyOS &operator=(const SoundDriver_HarmonyOS &) = delete;
};

/** Factory for the HarmonyOS sound driver. */
class FSoundDriver_HarmonyOS : public DriverFactoryBase {
public:
	FSoundDriver_HarmonyOS() : DriverFactoryBase(Driver::DT_SOUND, 10, "harmonyos", "HarmonyOS OHAudio Sound Driver (param hz)") {}
	std::unique_ptr<Driver> CreateInstance() const override { return std::make_unique<SoundDriver_HarmonyOS>(); }
};

/** The OHAudio renderer driving this sound driver. */
static OH_AudioRenderer *_audio_renderer = nullptr;

/** The negotiated output rate, kept across renderer recreation. */
static int32_t _negotiated_rate = 0;

/** Whether the output has been muted by a focus/duck interrupt. */
static bool _output_muted = false;
static bool _output_paused = false;
static std::atomic<bool> _renderer_failed{false};
static std::atomic<int> _pending_interrupt{-1};

extern "C" void OpenTTDHarmonyOSRestoreMusic(uint32_t rate);

/** Number of times we detected an empty/underrun callback delivery. */
static std::atomic<uint32_t> _callback_underruns{0};

static FSoundDriver_HarmonyOS iFSoundDriver_HarmonyOS;

/**
 * Callback that fills the OHAudio S16 stereo buffer via the OpenTTD mixer.
 *
 * OHAudio delivers `audioDataSize` bytes of interleaved S16LE stereo PCM.
 * MxMixSamples expects interleaved 2-channel signed 16-bit samples, so the
 * sample count is bytes / 4 (2 channels * 2 bytes). The mixer guarantees the
 * output is clipped into the signed 16-bit range and writes L/R in order, so
 * the native S16LE stereo layout matches the requested format exactly.
 */
static OH_AudioData_Callback_Result CDECL audio_write_data(OH_AudioRenderer *, void *, void *audioData, int32_t audioDataSize)
{
	HarmonyOSPerformance::Scope measure{HarmonyOSPerformance::Stage::Audio};
	/* Genuine underruns are surfaced by the OS underflow counter; we also
	 * flag non-positive callback buffers so the device test can correlate
	 * both signals. */
	if (audioData == nullptr || audioDataSize <= 0 || audioDataSize % 4 != 0) {
		_callback_underruns.fetch_add(1, std::memory_order_relaxed);
		if (audioData != nullptr && audioDataSize > 0) std::fill_n(static_cast<uint8_t *>(audioData), audioDataSize, 0);
		return AUDIO_DATA_CALLBACK_RESULT_INVALID;
	}
	MxMixSamples(audioData, audioDataSize / 4);

	return AUDIO_DATA_CALLBACK_RESULT_VALID;
}

/**
 * Handle audio focus / interruption events.
 *
 * OHAudio can force-pause our stream (phone call, alarm, another app taking
 * focus) or share control back to us. We must not call OH_AudioRenderer_Pause
 * on a stream the system already paused (illegal state); we only record the
 * state and, for SHARE-style resume requests, restart the renderer ourselves.
 */
static void CDECL audio_interrupt(OH_AudioRenderer *, void *, OH_AudioInterrupt_ForceType, OH_AudioInterrupt_Hint hint)
{
	/* Renderer calls and lifetime changes are owned by the game thread. */
	_pending_interrupt.store(static_cast<int>(hint), std::memory_order_release);
}

static void ApplyInterrupt(OH_AudioInterrupt_Hint hint)
{
	switch (hint) {
		case AUDIOSTREAM_INTERRUPT_HINT_RESUME:
			if (_audio_renderer != nullptr && !_output_paused) {
				OH_AudioRenderer_Start(_audio_renderer);
				Debug(driver, 2, "harmonyos_s: interrupt RESUME, output restarted");
			}
			break;

		case AUDIOSTREAM_INTERRUPT_HINT_PAUSE:
		case AUDIOSTREAM_INTERRUPT_HINT_STOP:
			/* System owns the pause; we just acknowledge it. */
			Debug(driver, 2, "harmonyos_s: system interrupt paused output");
			break;

		case AUDIOSTREAM_INTERRUPT_HINT_DUCK:
			if (_audio_renderer != nullptr) OH_AudioRenderer_SetVolume(_audio_renderer, 0.2f);
			_output_muted = true;
			Debug(driver, 2, "harmonyos_s: interrupt DUCK, volume lowered");
			break;

		case AUDIOSTREAM_INTERRUPT_HINT_UNDUCK:
			if (_audio_renderer != nullptr) OH_AudioRenderer_SetVolume(_audio_renderer, 1.0f);
			_output_muted = false;
			Debug(driver, 2, "harmonyos_s: interrupt UNDUCK, volume restored");
			break;

		case AUDIOSTREAM_INTERRUPT_HINT_MUTE:
			if (_audio_renderer != nullptr) OH_AudioRenderer_SetVolume(_audio_renderer, 0.0f);
			_output_muted = true;
			Debug(driver, 2, "harmonyos_s: interrupt MUTE");
			break;

		case AUDIOSTREAM_INTERRUPT_HINT_UNMUTE:
			if (_audio_renderer != nullptr) OH_AudioRenderer_SetVolume(_audio_renderer, 1.0f);
			_output_muted = false;
			Debug(driver, 2, "harmonyos_s: interrupt UNMUTE");
			break;

		default:
			break;
	}
}

/**
 * Handle renderer errors. OHAudio streams can error out (device removed,
 * routing failure, illegal state); we tear the renderer down so the next
 * interrupt resume / explicit ResumeOutput recreates it. We never crash the
 * game on an audio error.
 */
static void CDECL audio_error(OH_AudioRenderer *, void *, OH_AudioStream_Result error)
{
	Debug(driver, 1, "harmonyos_s: renderer error {}", (int)error);
	_renderer_failed.store(true, std::memory_order_release);
}

void SoundDriver_HarmonyOS::MainLoop()
{
	if (_renderer_failed.load(std::memory_order_acquire) && !_output_paused) this->ResumeOutput();
	int hint = _pending_interrupt.exchange(-1, std::memory_order_acq_rel);
	if (hint >= 0) ApplyInterrupt(static_cast<OH_AudioInterrupt_Hint>(hint));
}

std::optional<std::string_view> SoundDriver_HarmonyOS::Start(const StringList &param)
{
	/* Negotiate a supported sample rate. We prefer 48 kHz (the OpenTTD mixer
	 * is initialized once and all channels resample against it); if OHAudio
	 * rejects 48 kHz we fall back through the common rates rather than abort. */
	const int32_t requested = GetDriverParamInt(param, "hz", 48000);

	OH_AudioStreamBuilder *builder = nullptr;
	OH_AudioStream_Result res;

	OH_AudioStream_Usage usage = AUDIOSTREAM_USAGE_MUSIC;
	OH_AudioStream_LatencyMode latency = AUDIOSTREAM_LATENCY_MODE_NORMAL;
	OH_AudioStream_SampleFormat format = AUDIOSTREAM_SAMPLE_S16LE;
	OH_AudioChannelLayout layout = CH_LAYOUT_STEREO;

	int32_t rates_to_try[] = { requested, 48000, 44100, 32000, 22050 };
	int32_t chosen = 0;
	for (int32_t rate : rates_to_try) {
		if (rate <= 0) continue;

		res = OH_AudioStreamBuilder_Create(&builder, AUDIOSTREAM_TYPE_RENDERER);
		if (res != AUDIOSTREAM_SUCCESS) {
			return "harmonyos_s: OH_AudioStreamBuilder_Create failed";
		}

		OH_AudioStreamBuilder_SetRendererInfo(builder, usage);
		OH_AudioStreamBuilder_SetLatencyMode(builder, latency);
		OH_AudioStreamBuilder_SetSamplingRate(builder, rate);
		OH_AudioStreamBuilder_SetSampleFormat(builder, format);
		OH_AudioStreamBuilder_SetChannelLayout(builder, layout);
		OH_AudioStreamBuilder_SetEncodingType(builder, AUDIOSTREAM_ENCODING_TYPE_RAW);
		OH_AudioStreamBuilder_SetRendererWriteDataCallback(builder, audio_write_data, nullptr);
		OH_AudioStreamBuilder_SetRendererInterruptCallback(builder, audio_interrupt, nullptr);
		OH_AudioStreamBuilder_SetRendererErrorCallback(builder, audio_error, nullptr);

		OH_AudioRenderer *renderer = nullptr;
		res = OH_AudioStreamBuilder_GenerateRenderer(builder, &renderer);
		OH_AudioStreamBuilder_Destroy(builder);
		builder = nullptr;

		if (res != AUDIOSTREAM_SUCCESS) {
			Debug(driver, 1, "harmonyos_s: rate {} Hz rejected (error {})", rate, (int)res);
			continue;
		}

		/* OHAudio may have negotiated a different rate than we asked for. */
		chosen = rate;
		int32_t actual = 0;
		if (OH_AudioRenderer_GetSamplingRate(renderer, &actual) == AUDIOSTREAM_SUCCESS && actual > 0) {
			chosen = actual;
		}

		_negotiated_rate = chosen;
		_audio_renderer = renderer;
		_output_muted = false;
		_renderer_failed.store(false, std::memory_order_release);
		_callback_underruns.store(0, std::memory_order_relaxed);

		MxInitialize((uint)chosen);
		OpenTTDHarmonyOSRestoreMusic(chosen);

		res = OH_AudioRenderer_Start(renderer);
		if (res != AUDIOSTREAM_SUCCESS) {
			OH_AudioRenderer_Release(renderer);
			_audio_renderer = nullptr;
			return "harmonyos_s: OH_AudioRenderer_Start failed";
		}

		Debug(driver, 1, "harmonyos_s: started at {} Hz (requested {})", chosen, requested);
		return std::nullopt;
	}

	return "harmonyos_s: no supported sample rate";
}

void SoundDriver_HarmonyOS::Stop()
{
	if (_audio_renderer != nullptr) {
		OH_AudioRenderer_Stop(_audio_renderer);
		OH_AudioRenderer_Release(_audio_renderer);
		_audio_renderer = nullptr;
	}
	_negotiated_rate = 0;
	_output_muted = false;
	_renderer_failed.store(false, std::memory_order_release);
	_pending_interrupt.store(-1, std::memory_order_release);
}

/**
 * Pause the output. Intended to be driven when the app moves to the
 * background; keeps the renderer alive but stops pulling audio.
 */
void SoundDriver_HarmonyOS::PauseOutput()
{
	_output_paused = true;
	if (_audio_renderer != nullptr) {
		OH_AudioRenderer_Pause(_audio_renderer);
		Debug(driver, 2, "harmonyos_s: output paused");
	}
}

/**
 * Resume the output after a background pause or an interrupt RESUME.
 */
void SoundDriver_HarmonyOS::ResumeOutput()
{
	_output_paused = false;
	if (_renderer_failed.exchange(false, std::memory_order_acq_rel) && _audio_renderer != nullptr) {
		OH_AudioRenderer_Release(_audio_renderer);
		_audio_renderer = nullptr;
	}
	if (_audio_renderer == nullptr) {
		/* The renderer was torn down by an error callback; recreate it with
		 * the last negotiated rate so the mixer resample stays consistent. */
		Debug(driver, 1, "harmonyos_s: recreating renderer at {} Hz", _negotiated_rate);
		if (_negotiated_rate > 0) {
			StringList parm{};
			parm.push_back(fmt::format("hz={}", _negotiated_rate));
			if (Start(parm)) {
				Debug(driver, 0, "harmonyos_s: renderer recreation failed");
				return;
			}
			return;
		}
		return;
	}

	OH_AudioRenderer_Start(_audio_renderer);
	Debug(driver, 2, "harmonyos_s: output resumed");
}

/** Number of OS-reported underflows since the renderer started. */
uint32_t SoundDriver_HarmonyOS::GetUnderflowCount() const
{
	if (_audio_renderer == nullptr) return 0;
	uint32_t count = 0;
	if (OH_AudioRenderer_GetUnderflowCount(_audio_renderer, &count) != AUDIOSTREAM_SUCCESS) {
		return _callback_underruns.load(std::memory_order_relaxed);
	}
	return count;
}

extern "C" void OpenTTDHarmonyOSPauseAudio()
{
	SoundDriver *driver = SoundDriver::GetInstance();
	if (driver != nullptr && driver->GetName() == "harmonyos") static_cast<SoundDriver_HarmonyOS *>(driver)->PauseOutput();
}

extern "C" void OpenTTDHarmonyOSResumeAudio()
{
	SoundDriver *driver = SoundDriver::GetInstance();
	if (driver != nullptr && driver->GetName() == "harmonyos") static_cast<SoundDriver_HarmonyOS *>(driver)->ResumeOutput();
}

#endif /* WITH_HARMONYOS */
