/* HarmonyOS edit-box state is published on the game thread, copied by the UI. */
#ifndef VIDEO_HARMONYOS_TEXTINPUT_H
#define VIDEO_HARMONYOS_TEXTINPUT_H

struct HarmonyOSInputEvent;
void HarmonyOSUpdateTextInputState();
void HarmonyOSCancelTextComposition();
void HarmonyOSApplyTextInput(const HarmonyOSInputEvent &event);
bool HarmonyOSTextInputSessionMatches(uint32_t session);

#endif
