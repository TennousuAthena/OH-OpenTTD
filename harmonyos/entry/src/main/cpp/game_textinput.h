// Shared C ABI between the game engine and its NAPI host. No SDK dependencies.
#pragma once

#include <cstdint>

struct HarmonyOSTextInputState {
    uint32_t session = 0;
    uint32_t sequence = 0;
    bool active = false;
    int32_t left = 0;
    int32_t top = 0;
    int32_t width = 0;
    int32_t height = 0;
    int32_t caret = 0; // UTF-16 units, as used by ArkUI.
    int32_t max_chars = 0;
    char text[65536]{};
};
