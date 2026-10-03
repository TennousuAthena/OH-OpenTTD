# CMakeLists.txt — builds libentry.so (the OpenTTD HarmonyOS native host).
#
# libentry.so provides:
#   * the NAPI module "entry" (registered via napi_init.cpp), which exposes
#     drawPattern / changeColor / getLifecycleState to ArkTS;
#   * the XComponent surface lifecycle glue that drives the pure-C++
#     lifecycle_bridge state machine;
#   * a dlopen of libopenttd.so (the game core) on surface creation.
#
# This file is invoked by hvigor's externalNativeOptions using the OHOS
# toolchain (see entry/build-profile.json5).

cmake_minimum_required(VERSION 3.17)

project(openttd_ohos_entry)

set(NATIVE_ROOT ${CMAKE_CURRENT_SOURCE_DIR})
get_filename_component(OPEN_TTD_ROOT "${NATIVE_ROOT}/../../../../.." ABSOLUTE)
include("${OPEN_TTD_ROOT}/cmake/HarmonyOSPerformance.cmake")

# bridge_textinput.h uses std::optional / std::nullopt (C++17).
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# --- libentry.so (NAPI host + lifecycle bridge + XComponent glue) ---------
add_library(entry SHARED
    ${NATIVE_ROOT}/napi_init.cpp
    ${NATIVE_ROOT}/lifecycle_bridge.cpp
    ${NATIVE_ROOT}/bridge_napi.cpp
    ${NATIVE_ROOT}/bridge_textinput.cpp
    ${NATIVE_ROOT}/bridge_picker.cpp
    ${NATIVE_ROOT}/bridge_system.cpp
)
harmonyos_native_compile_options(entry)

target_include_directories(entry PRIVATE
    ${NATIVE_ROOT}
)

target_link_libraries(entry
    ace_ndk.z
    ace_napi.z
    native_window.so
    hilog_ndk.z
)

include(ExternalProject)
set(OPEN_TTD_HOST_BINARY_DIR "${OPEN_TTD_ROOT}/build/host-tools" CACHE PATH
    "Directory containing native-host strgen/settingsgen exports")
set(OPEN_TTD_ENGINE_BUILD_DIR "${CMAKE_CURRENT_BINARY_DIR}/openttd-engine")
set(OPEN_TTD_ENGINE_BUILD_JOBS 4 CACHE STRING "Parallel jobs per engine ABI")

set(OPEN_TTD_ENGINE_CMAKE_ARGS
    -DCMAKE_TOOLCHAIN_FILE=${OPEN_TTD_ROOT}/cmake/HarmonyOSNativeToolchain.cmake
    -DHARMONYOS_SDK_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE}
    # Forward platform variables to whole-project try_compile() calls (IPO).
    -DCMAKE_POLICY_DEFAULT_CMP0137=NEW
    -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}
    -DOPENTTD_HARMONYOS_OPTIMIZE=${OPENTTD_HARMONYOS_OPTIMIZE}
    -DOPENTTD_HARMONYOS_PERF=${OPENTTD_HARMONYOS_PERF}
    -DOPENTTD_HARMONYOS_VERBOSE_LOG=${OPENTTD_HARMONYOS_VERBOSE_LOG}
    -DCMAKE_MAKE_PROGRAM=${CMAKE_MAKE_PROGRAM}
    -DHOST_BINARY_DIR=${OPEN_TTD_HOST_BINARY_DIR}
    -DOHOS_ARCH=${OHOS_ARCH}
    -DOHOS_PLATFORM_LEVEL=${OHOS_PLATFORM_LEVEL}
    -DBUILD_TESTING=OFF
)

# The HarmonyOS wrapper toolchain needs both SDK roots before project() loads
# it. ExternalProject has its own cache and cannot inherit Hvigor's variables.
foreach(variable OHOS_SDK_NATIVE HMOS_SDK_NATIVE OHOS_STL
        OHOS_COMPATIBLE_SDK_VERSION OHOS_SDK_NATIVE_PLATFORM)
    if(DEFINED ${variable})
        list(APPEND OPEN_TTD_ENGINE_CMAKE_ARGS "-D${variable}=${${variable}}")
    endif()
endforeach()

set(OPEN_TTD_RUNTIME_DEPS_DIR "${OPEN_TTD_ROOT}/build/harmonyos/runtime-deps/${OHOS_ARCH}"
    CACHE PATH "Compiled HarmonyOS dependencies for this ABI")
if(NOT EXISTS "${OPEN_TTD_RUNTIME_DEPS_DIR}/lib/liblzma.a")
    message(FATAL_ERROR "Build liblzma for both ABIs with scripts/harmonyos/build-runtime-deps.py before building the game")
endif()
if(NOT EXISTS "${OPEN_TTD_RUNTIME_DEPS_DIR}/lib/libfreetype.a")
    message(FATAL_ERROR "Build FreeType for both ABIs with scripts/harmonyos/build-runtime-deps.py --dep freetype before building the game")
endif()
list(APPEND OPEN_TTD_ENGINE_CMAKE_ARGS
    "-DLIBLZMA_LIBRARY=${OPEN_TTD_RUNTIME_DEPS_DIR}/lib/liblzma.a"
    "-DLIBLZMA_INCLUDE_DIR=${OPEN_TTD_RUNTIME_DEPS_DIR}/include"
    "-DFREETYPE_LIBRARY_RELEASE=${OPEN_TTD_RUNTIME_DEPS_DIR}/lib/libfreetype.a"
    "-DFREETYPE_INCLUDE_DIR_ft2build=${OPEN_TTD_RUNTIME_DEPS_DIR}/include/freetype2"
    "-DFREETYPE_INCLUDE_DIR_freetype2=${OPEN_TTD_RUNTIME_DEPS_DIR}/include/freetype2"
)

ExternalProject_Add(openttd_engine
    SOURCE_DIR "${OPEN_TTD_ROOT}"
    BINARY_DIR "${OPEN_TTD_ENGINE_BUILD_DIR}"
    CMAKE_GENERATOR "${CMAKE_GENERATOR}"
    CMAKE_ARGS ${OPEN_TTD_ENGINE_CMAKE_ARGS}
    BUILD_COMMAND "${CMAKE_COMMAND}" --build . --target openttd --parallel ${OPEN_TTD_ENGINE_BUILD_JOBS}
    BUILD_ALWAYS TRUE
    INSTALL_COMMAND ""
    BUILD_BYPRODUCTS "${OPEN_TTD_ENGINE_BUILD_DIR}/libopenttd.so"
)

add_custom_command(TARGET openttd_engine POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
        "${OPEN_TTD_ENGINE_BUILD_DIR}/libopenttd.so"
        "$<TARGET_FILE_DIR:entry>/libopenttd.so"
)
