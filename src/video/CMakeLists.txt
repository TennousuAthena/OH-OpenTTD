add_subdirectory(cocoa)

if(NOT OPTION_DEDICATED)
    add_files(
        allegro_v.cpp
        allegro_v.h
        CONDITION Allegro_FOUND
    )

    add_files(
        opengl.cpp
        opengl.h
        CONDITION OPENGL_FOUND
    )

    add_files(
        sdl2_v.cpp
        sdl2_v.h
        sdl2_default_v.cpp
        sdl2_default_v.h
        CONDITION SDL2_FOUND
    )

    add_files(
        sdl2_opengl_v.cpp
        sdl2_opengl_v.h
        CONDITION SDL2_FOUND AND OPENGL_FOUND
    )

    add_files(
        harmonyos_v.cpp
        harmonyos_v.h
        harmonyos_performance.h
        harmonyos_input.cpp
        harmonyos_input.h
        harmonyos_textinput.cpp
        harmonyos_textinput.h
        harmonyos_touch.cpp
        harmonyos_touch.h
        CONDITION HARMONYOS
    )

    if(HARMONYOS)
        # Define the HARMONYOS compile macro the video/input/touch sources guard
        # on (mirroring WITH_HARMONYOS for the sound driver in src/sound), so the
        # driver body is actually compiled on the OHOS target.
        target_compile_definitions(openttd_lib PRIVATE HARMONYOS OHOS_PLATFORM)
        target_include_directories(openttd_lib PRIVATE ${CMAKE_SOURCE_DIR}/harmonyos/entry/src/main/cpp)
        target_sources(openttd_lib PRIVATE ${CMAKE_SOURCE_DIR}/harmonyos/entry/src/main/cpp/lifecycle_bridge.cpp)
        target_link_libraries(openttd_lib EGL GLESv3 native_window ace_ndk.z)
    endif()

    add_files(
        win32_v.cpp
        win32_v.h
        CONDITION WIN32
    )
endif()

add_files(
    dedicated_v.cpp
    dedicated_v.h
    null_v.cpp
    null_v.h
    video_driver.cpp
    video_driver.hpp
)
