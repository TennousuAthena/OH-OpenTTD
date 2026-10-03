# This port retains the OpenTTD 15.3 simulation, savegame and wire protocol.
# Bump the upstream baseline only after rebasing and checking multiplayer
# compatibility. Platform release numbers belong in the display version.
set(HARMONYOS_UPSTREAM_VERSION "15.3")
set(HARMONYOS_UPSTREAM_REVISION "14ec60f248547d4d062a1160f0fc26d742319888")
set(HARMONYOS_PORT_REVISION "2")
set(HARMONYOS_DISPLAY_VERSION "${HARMONYOS_UPSTREAM_VERSION}-harmonyos.${HARMONYOS_PORT_REVISION}")
