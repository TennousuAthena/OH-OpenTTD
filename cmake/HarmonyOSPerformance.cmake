# Shared native build policy for the Hvigor host and the game engine. Debug
# signing does not imply an unoptimized game: DevEco normally launches Debug.
foreach(option_name OPENTTD_HARMONYOS_OPTIMIZE OPENTTD_HARMONYOS_PERF OPENTTD_HARMONYOS_VERBOSE_LOG)
    if(DEFINED ENV{${option_name}})
        string(TOUPPER "$ENV{${option_name}}" option_value)
        if(NOT option_value MATCHES "^(ON|OFF|TRUE|FALSE|1|0)$")
            message(FATAL_ERROR "${option_name} must be ON or OFF")
        endif()
        set(${option_name} "${option_value}" CACHE BOOL "HarmonyOS native build option" FORCE)
    endif()
endforeach()

option(OPENTTD_HARMONYOS_OPTIMIZE "Optimize HarmonyOS native code, including Debug builds" ON)
option(OPENTTD_HARMONYOS_PERF "Collect HarmonyOS per-second performance diagnostics" OFF)
option(OPENTTD_HARMONYOS_VERBOSE_LOG "Enable verbose HarmonyOS startup/driver diagnostics" OFF)
get_filename_component(OPENTTD_HARMONYOS_SOURCE_ROOT "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)

if(NOT OPENTTD_HARMONYOS_OPTIMIZE AND NOT CMAKE_BUILD_TYPE STREQUAL "Debug")
    message(FATAL_ERROR "OPENTTD_HARMONYOS_OPTIMIZE=OFF is only supported for deliberate Debug builds")
endif()

function(harmonyos_native_compile_options target)
    # Target options follow the SDK's configuration flags, so -O2 overrides
    # its Debug -O0 while preserving -g for local debugging and symbolication.
    if(OPENTTD_HARMONYOS_OPTIMIZE)
        target_compile_options(${target} PRIVATE -O2 -g)
        target_compile_definitions(${target} PRIVATE OPENTTD_HARMONYOS_OPTIMIZED)
    else()
        target_compile_options(${target} PRIVATE -O0 -g)
    endif()
    target_compile_options(${target} PRIVATE "-ffile-prefix-map=${OPENTTD_HARMONYOS_SOURCE_ROOT}=.")
    if(OPENTTD_HARMONYOS_VERBOSE_LOG)
        target_compile_definitions(${target} PRIVATE OPENTTD_HARMONYOS_VERBOSE_LOG)
    endif()
endfunction()
