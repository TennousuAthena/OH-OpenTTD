if(NOT OPTION_DEDICATED)
    add_files(
        allegro_s.cpp
        allegro_s.h
        CONDITION Allegro_FOUND
    )

    add_files(
        sdl2_s.cpp
        sdl_s.h
        CONDITION SDL2_FOUND
    )

    add_files(
        cocoa_s.cpp
        cocoa_s.h
        CONDITION APPLE
    )

    add_files(
        win32_s.cpp
        win32_s.h
        CONDITION WIN32
    )

    add_files(
        xaudio2_s.cpp
        xaudio2_s.h
        CONDITION WIN32 AND XAUDIO2_FOUND
    )

    add_files(
        harmonyos_s.cpp
        CONDITION HARMONYOS
    )
endif()

add_files(
    sound_driver.hpp
    null_s.cpp
    null_s.h
)

if(HARMONYOS)
    # The HarmonyOS sound driver needs the OHAudio C API. Guard it with its
    # own define (mirroring WITH_SDL2/WITH_COCOA) so the .cpp can be
    # preprocessed standalone, and link libohaudio.so from the OHOS sysroot.
    target_compile_definitions(openttd_lib PRIVATE WITH_HARMONYOS)
    target_link_libraries(openttd_lib ohaudio)
endif()
