# TinySoundFont integration

Unmodified `tsf.h` and `LICENSE` from
https://github.com/schellingb/TinySoundFont/tree/853a0a171759f1ddba0de1442133a75912bbeffa
(MIT, retrieved 2026-10-03).

The HarmonyOS driver uses the existing OpenTTD MIDI parser and feeds stereo
PCM into its mixer. Only the bundled, checksum-verified TimGM6mb SoundFont
is loaded. It has no user-selectable SoundFont path.

TimGM6mb comes from Debian's `timgm6mb-soundfont_1.3.orig.tar.gz`,
SHA256 `af8f3a00e416dfb262bcaa904a1c84df04a51b72bbc1313aed012bc754bdf99b`.
Its copyright notice is in `TimGM6mb-NOTICE.txt`; the GPLv2 license is
in the project COPYING.md and is also included in the application's data.
The binary SoundFont is downloaded and staged by stage-assets.py.
