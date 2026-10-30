cmake_minimum_required(VERSION 3.22.1)

project(playintegrityfix)

find_package(cxx REQUIRED CONFIG)

link_libraries(cxx::cxx)

enable_language(C CXX ASM)

set(PIF_VENDOR_DIR "${CMAKE_CURRENT_SOURCE_DIR}" CACHE PATH "Pinned engine dependencies")
set(bytehook_SOURCE_DIR "${PIF_VENDOR_DIR}/bytehook")

file(GLOB BYTEHOOK_SRC ${bytehook_SOURCE_DIR}/bytehook/src/main/cpp/*.c)
# The Java API shim is not used by the native engine; its trampolines select their
# architecture-specific code paths internally, so one source list serves all four ABIs.
list(FILTER BYTEHOOK_SRC EXCLUDE REGEX "bh_jni\\.c$")

include_directories(
    ${bytehook_SOURCE_DIR}/bytehook/src/main/cpp
    ${bytehook_SOURCE_DIR}/bytehook/src/main/cpp/include
    ${bytehook_SOURCE_DIR}/bytehook/src/main/cpp/third_party/bsd
    ${bytehook_SOURCE_DIR}/bytehook/src/main/cpp/third_party/lss
)

add_library(${CMAKE_PROJECT_NAME} SHARED main.cpp companion.cpp config.cpp property_hook.cpp java_injection.cpp observation.cpp ${PIF_VENDOR_DIR}/local_cxa_atexit_finalize_impl/atexit.cpp ${BYTEHOOK_SRC})

target_link_libraries(${CMAKE_PROJECT_NAME} PRIVATE log)

set(PIF_MODULE_DIR "/data/adb/modules/duck-toolbox/play-integrity" CACHE STRING "Engine payload directory")
set(PIF_DATA_DIR "/data/adb/play-integrity" CACHE STRING "Engine state directory")
target_compile_definitions(${CMAKE_PROJECT_NAME} PRIVATE
    PIF_MODULE_DIR="${PIF_MODULE_DIR}"
    PIF_DATA_DIR="${PIF_DATA_DIR}"
)
