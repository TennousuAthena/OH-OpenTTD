/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License, version 2.
 * See COPYING.md for the license and warranty disclaimer.
 */

/** @file harmonyos_m.cpp Software MIDI playback through the OHAudio mixer. */

#include "../stdafx.h"
#include <atomic>
#include <mutex>
#include "../base_media_music.h"
#include "../debug.h"
#include "../fileio_func.h"
#include "../mixer.h"
#include "music_driver.hpp"
#include "midifile.hpp"
#include "../video/harmonyos_performance.h"

/* Keep the upstream header unchanged, with its implementation in this TU only. */
#define TSF_IMPLEMENTATION
#define TSF_STATIC
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
#pragma GCC diagnostic ignored "-Wundef"
#pragma GCC diagnostic ignored "-Wnull-pointer-subtraction"
#include "../3rdparty/tinysoundfont/tsf.h"
#pragma GCC diagnostic pop

#include "../safeguards.h"

namespace {

struct MidiPlayback {
	std::mutex mutex;
	tsf *synth = nullptr;
	MidiFile file;
	uint32_t rate = 0;
	size_t block = 0;
	size_t end_block = 0;
	uint64_t frame = 0;
	uint64_t start_frame = 0;
	uint64_t end_frame = 0;
	/* Status polling runs while holding the game-state lock. It must not wait
	 * for a full audio synthesis callback; synth/file access still uses mutex. */
	std::atomic<bool> playing{false};
	bool loop = false;
	bool reported_pcm = false;
	uint8_t volume = 127;
} _midi;

std::unique_lock<std::mutex> LockMidiControls()
{
	const auto begin = HarmonyOSPerformance::Now();
	std::unique_lock<std::mutex> lock{_midi.mutex};
	HarmonyOSPerformance::Record(HarmonyOSPerformance::Stage::MusicLock, HarmonyOSPerformance::Now() - begin);
	return lock;
}

uint64_t MicrosecondsToFrames(int64_t time)
{
	return static_cast<uint64_t>(std::max<int64_t>(time, 0)) * _midi.rate / 1000000;
}

uint64_t TickToFrame(uint32_t tick)
{
	uint32_t last_tick = 0;
	uint32_t tempo = 500000;
	uint64_t time = 0;
	for (const auto &change : _midi.file.tempos) {
		if (change.ticktime >= tick) break;
		time += uint64_t(change.ticktime - last_tick) * tempo / _midi.file.tickdiv;
		last_tick = change.ticktime;
		tempo = change.tempo;
	}
	time += uint64_t(tick - last_tick) * tempo / _midi.file.tickdiv;
	return time * _midi.rate / 1000000;
}

void ResetChannels()
{
	/* Retain the preallocated channels and voices in the audio callback. */
	for (int channel = 0; channel < 16; channel++) {
		tsf_channel_sounds_off_all(_midi.synth, channel);
		tsf_channel_midi_control(_midi.synth, channel, MIDICT_MODE_RESETALLCTRL, 0);
		tsf_channel_set_sustain(_midi.synth, channel, 0);
		tsf_channel_set_pitchwheel(_midi.synth, channel, 8192);
		tsf_channel_set_presetnumber(_midi.synth, channel, 0, channel == 9);
	}
}

void SendBlock(const MidiFile::DataBlock &block, bool notes)
{
	const auto &data = block.data;
	for (size_t pos = 0; pos < data.size();) {
		uint8_t status = data[pos++];
		if (status == MIDIST_SYSEX) {
			/* Honor GM/GS/XG reset messages, ignore device-specific effects. */
			size_t begin = pos - 1;
			while (pos < data.size() && data[pos] != MIDIST_ENDSYSEX) pos++;
			if (pos == data.size()) return;
			pos++;
			for (auto reset : {MidiSysexMessage::ResetGM, MidiSysexMessage::ResetGS, MidiSysexMessage::ResetXG}) {
				size_t length;
				const auto *message = MidiGetStandardSysexMessage(reset, length);
				if (pos - begin == length && std::equal(message, message + length, data.begin() + begin)) ResetChannels();
			}
			continue;
		}
		if (status < MIDIST_NOTEOFF || status >= MIDIST_SYSEX) return;
		uint8_t type = status & 0xF0;
		int channel = status & 0x0F;
		size_t length = type == MIDIST_PROGCHG || type == MIDIST_CHANPRESS ? 1 : 2;
		if (data.size() - pos < length) return;
		uint8_t first = data[pos++] & 0x7F;
		uint8_t second = length == 2 ? data[pos++] & 0x7F : 0;
		switch (type) {
			case MIDIST_NOTEOFF: if (notes) tsf_channel_note_off(_midi.synth, channel, first); break;
			case MIDIST_NOTEON: if (notes) tsf_channel_note_on(_midi.synth, channel, first, second / 127.0f); break;
			case MIDIST_CONTROLLER: tsf_channel_midi_control(_midi.synth, channel, first, second); break;
			case MIDIST_PROGCHG: tsf_channel_set_presetnumber(_midi.synth, channel, first, channel == 9); break;
			case MIDIST_PITCHBEND: tsf_channel_set_pitchwheel(_midi.synth, channel, first | (second << 7)); break;
			default: break; // Polyphonic/channel pressure is not supported by this synthesizer.
		}
	}
}

void RewindSong()
{
	ResetChannels();
	_midi.frame = _midi.start_frame;
	_midi.block = 0;
	/* Apply initial controllers and programs without playing skipped notes. */
	while (_midi.block < _midi.end_block && MicrosecondsToFrames(_midi.file.blocks[_midi.block].realtime) < _midi.start_frame) {
		SendBlock(_midi.file.blocks[_midi.block++], false);
	}
}

void RenderMusic(int16_t *buffer, size_t frames)
{
	HarmonyOSPerformance::Scope measure{HarmonyOSPerformance::Stage::MusicRender};
	std::unique_lock lock{_midi.mutex, std::try_to_lock};
	if (!lock.owns_lock() || _midi.synth == nullptr || !_midi.playing) return;
	while (frames > 0 && _midi.playing) {
		if (_midi.frame >= _midi.end_frame) {
			if (_midi.loop) {
				RewindSong();
			} else {
				tsf_note_off_all(_midi.synth);
				_midi.playing = false;
				break;
			}
		}
		while (_midi.block < _midi.end_block && MicrosecondsToFrames(_midi.file.blocks[_midi.block].realtime) <= _midi.frame) {
			SendBlock(_midi.file.blocks[_midi.block++], true);
		}
		uint64_t next_frame = _midi.block < _midi.end_block ?
			MicrosecondsToFrames(_midi.file.blocks[_midi.block].realtime) : _midi.end_frame;
		next_frame = std::min(next_frame, _midi.end_frame);
		size_t count = std::min<uint64_t>(frames, next_frame - _midi.frame);
		count = std::min<size_t>(count, INT_MAX);
		tsf_render_short(_midi.synth, buffer, static_cast<int>(count), 0);
		if (!_midi.reported_pcm && std::any_of(buffer, buffer + count * 2, [](int16_t sample) { return sample != 0; })) {
			_midi.reported_pcm = true;
			Debug(driver, 1, "harmonyos_m: MIDI produced nonzero stereo PCM at {} Hz", _midi.rate);
		}
		buffer += count * 2;
		frames -= count;
		_midi.frame += count;
	}
}

class MusicDriver_HarmonyOS : public MusicDriver {
public:
	std::optional<std::string_view> Start(const StringList &) override
	{
		const std::string font = FioFindFullPath(Subdirectory::BASESET_DIR, "TimGM6mb.sf2");
		if (font.empty()) return "Bundled TimGM6mb SoundFont is missing";
		_midi.synth = tsf_load_filename(font.c_str());
		if (_midi.synth == nullptr) return "Could not load bundled TimGM6mb SoundFont";
		if (!tsf_set_max_voices(_midi.synth, 256) || !tsf_channel_set_presetnumber(_midi.synth, 15, 0)) {
			tsf_close(_midi.synth);
			_midi.synth = nullptr;
			return "Could not allocate MIDI voices/channels";
		}
		ResetChannels();
		_midi.rate = MxSetMusicSource(nullptr);
		tsf_set_output(_midi.synth, TSF_STEREO_INTERLEAVED, _midi.rate, -14.0f);
		MxSetMusicSource(RenderMusic);
		Debug(driver, 1, "harmonyos_m: {} presets, {} Hz, 256 voices", tsf_get_presetcount(_midi.synth), _midi.rate);
		return std::nullopt;
	}

	void Stop() override
	{
		MxSetMusicSource(nullptr);
		auto lock = LockMidiControls();
		_midi.playing = false;
		tsf_close(_midi.synth);
		_midi.synth = nullptr;
		_midi.file.blocks.clear();
		_midi.file.tempos.clear();
	}

	void PlaySong(const MusicSongInfo &song) override
	{
		MidiFile file;
		bool loaded = file.LoadSong(song) && !file.blocks.empty() && file.tickdiv != 0;
		auto lock = LockMidiControls();
		_midi.playing = false;
		if (_midi.synth == nullptr) return;
		ResetChannels();
		if (!loaded) {
			Debug(driver, 0, "harmonyos_m: could not load '{}'", song.filename);
			return;
		}
		_midi.file.MoveFrom(file);
		_midi.start_frame = TickToFrame(std::max(song.override_start, 0));
		_midi.end_frame = song.override_end > 0 ? TickToFrame(song.override_end) :
			MicrosecondsToFrames(_midi.file.blocks.back().realtime) + (song.loop ? 1 : _midi.rate * 2);
		_midi.end_block = _midi.file.blocks.size();
		if (song.override_end > 0) {
			_midi.end_block = std::lower_bound(_midi.file.blocks.begin(), _midi.file.blocks.end(), song.override_end,
				[](const auto &block, int tick) { return block.ticktime < static_cast<uint32_t>(tick); }) - _midi.file.blocks.begin();
		}
		_midi.loop = song.loop;
		_midi.reported_pcm = false;
		RewindSong();
		_midi.playing = _midi.end_frame > _midi.start_frame;
		Debug(driver, 1, "harmonyos_m: playing '{}', {} blocks, loop={}", song.songname, _midi.end_block, song.loop);
	}

	void StopSong() override
	{
		auto lock = LockMidiControls();
		_midi.playing = false;
		if (_midi.synth != nullptr) ResetChannels();
	}

	bool IsSongPlaying() override
	{
		return _midi.playing.load(std::memory_order_relaxed);
	}

	void SetVolume(uint8_t volume) override
	{
		auto lock = LockMidiControls();
		_midi.volume = volume;
		if (_midi.synth != nullptr) tsf_set_volume(_midi.synth, volume / (128.0f * 5.0f));
	}

	std::string_view GetName() const override { return "harmonyos"; }
};

class FMusicDriver_HarmonyOS : public DriverFactoryBase {
public:
	FMusicDriver_HarmonyOS() : DriverFactoryBase(Driver::DT_MUSIC, 10, "harmonyos", "HarmonyOS software MIDI driver") {}
	std::unique_ptr<Driver> CreateInstance() const override { return std::make_unique<MusicDriver_HarmonyOS>(); }
} _factory;

} // namespace

/** Reconnect the sampled music stream after OHAudio recreates its mixer. */
extern "C" void OpenTTDHarmonyOSRestoreMusic(uint32_t rate)
{
	{
		auto lock = LockMidiControls();
		if (_midi.synth == nullptr) return;
		if (_midi.rate != rate) {
			_midi.frame = _midi.frame * rate / _midi.rate;
			_midi.start_frame = _midi.start_frame * rate / _midi.rate;
			_midi.end_frame = _midi.end_frame * rate / _midi.rate;
			_midi.rate = rate;
			tsf_set_output(_midi.synth, TSF_STEREO_INTERLEAVED, rate, -14.0f);
			tsf_set_volume(_midi.synth, _midi.volume / (128.0f * 5.0f));
		}
	}
	/* The mixer takes its own lock before calling RenderMusic. */
	MxSetMusicSource(RenderMusic);
}
