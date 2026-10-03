# Preserve the active DevEco toolchain in ExternalProject and try_compile().
if(NOT HARMONYOS_SDK_TOOLCHAIN_FILE)
    message(FATAL_ERROR "HARMONYOS_SDK_TOOLCHAIN_FILE must name the active SDK toolchain")
endif()

include("${HARMONYOS_SDK_TOOLCHAIN_FILE}")

# The HMOS wrapper exports both SDK roots, but its included OHOS toolchain
# replaces that list. Restore the wrapper parameters after both have loaded.
list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES
    HARMONYOS_SDK_TOOLCHAIN_FILE
    OHOS_SDK_NATIVE
    HMOS_SDK_NATIVE
    OHOS_ARCH
    OHOS_STL
    OHOS_PLATFORM_LEVEL
    OHOS_COMPATIBLE_SDK_VERSION
    OHOS_SDK_NATIVE_PLATFORM
)
list(REMOVE_DUPLICATES CMAKE_TRY_COMPILE_PLATFORM_VARIABLES)
