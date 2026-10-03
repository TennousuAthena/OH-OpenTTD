add_files(
    crashlog_unix.cpp
    survey_unix.cpp
    CONDITION UNIX AND NOT APPLE AND NOT HARMONYOS
)

add_files(
    library_loader_unix.cpp
    unix.cpp
    CONDITION UNIX AND NOT HARMONYOS
)

add_files(
    font_unix.cpp
    font_unix.h
    CONDITION Fontconfig_FOUND
)

if(UNIX AND NOT APPLE AND NOT HARMONYOS)
    target_sources(openttd PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/unix_main.cpp)
endif()
