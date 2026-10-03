# HarmonyOS platform detection and source-list governance.
#
# HarmonyOS is NOT a generic desktop Linux. The official OHOS CMake toolchain
# sets CMAKE_SYSTEM_NAME=OHOS, but it also sets UNIX=1 (like the Android
# toolchain does). If we left `if(UNIX)` blocks alone, HarmonyOS would silently
# pull in unix_main.cpp / crashlog_unix.cpp / extmidi.cpp and the fork/exec /
# execinfo(-rdynamic) code paths that do not exist on the target. We therefore
# detect HarmonyOS explicitly and exclude those sources below.
#
# Usage (must be included early in the top-level CMakeLists.txt):
#   include(HarmonyOS)

# HARMONYOS is true when the OHOS toolchain is in use. The toolchain sets the
# variable OHOS=OHOS and CMAKE_SYSTEM_NAME=OHOS. We accept either so that the
# guard also works if a wrapper toolchain omits one of them.
if(OHOS OR CMAKE_SYSTEM_NAME STREQUAL "OHOS")
    set(HARMONYOS TRUE)
endif()

# ---------------------------------------------------------------------------
# Forbidden source guard.
#
# Assert that none of the Unix-only / fork-exec / execinfo sources were added to
# the given target. Called after add_subdirectory(src) so that every target_sources()
# has already run. On HARMONYOS these files must never be compiled; if one is
# present it is a sign that a generic-UNIX path leaked in, and we refuse loudly.
# ---------------------------------------------------------------------------
function(assert_no_forbidden_harmonyos_sources target_name)
    if(NOT HARMONYOS)
        return()
    endif()

    get_target_property(_tgt_sources ${target_name} SOURCES)
    if(NOT _tgt_sources OR _tgt_sources STREQUAL "${target_name}-NOTFOUND")
        return()
    endif()

    foreach(_forbidden unix_main.cpp crashlog_unix.cpp extmidi.cpp unix.cpp library_loader_unix.cpp survey_unix.cpp)
        # SOURCES entries are absolute paths; match on the filename component.
        foreach(_src ${_tgt_sources})
            get_filename_component(_name "${_src}" NAME)
            if(_name STREQUAL "${_forbidden}")
                message(FATAL_ERROR
                    "HARMONYOS platform guard: forbidden Unix-only source '${_forbidden}' "
                    "is present in target '${target_name}' (${_src}). "
                    "HarmonyOS must not impersonate generic Unix; remove the generic-UNIX gate "
                    "or add an 'AND NOT HARMONYOS' guard.")
            endif()
        endforeach()
    endforeach()
endfunction()
