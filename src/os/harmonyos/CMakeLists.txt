# HarmonyOS OS abstraction layer.
#
# These shims replace the generic-Unix layer (src/os/unix) on HarmonyOS without
# pulling in fork/exec/execinfo code. They are only compiled when the OHOS
# toolchain is active (HARMONYOS).

add_files(
    crashlog_harmonyos.cpp
    harmonyos.cpp
    harmonyos_log.cpp
    library_loader_harmonyos.cpp
    survey_harmonyos.cpp
    CONDITION HARMONYOS
)

add_files(
    font_harmonyos.cpp
    font_harmonyos.h
    CONDITION HARMONYOS AND Freetype_FOUND
)

if(HARMONYOS)
    target_link_libraries(openttd_lib hiappevent_ndk.z hilog_ndk.z)
    if(Freetype_FOUND)
        target_link_libraries(openttd_lib native_drawing)
    endif()
    target_sources(openttd PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/harmonyos_main.cpp)
    target_compile_definitions(openttd PRIVATE $<$<CONFIG:Debug>:OPENTTD_HARMONYOS_DEBUG>)
endif()
