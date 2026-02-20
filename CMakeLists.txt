cmake_minimum_required(VERSION 3.22)
project(stt_tts_audio_bridge LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT APPLE)
  message(FATAL_ERROR "This project targets macOS only.")
endif()

set(COMMON_SOURCES
  src/common/SharedMemoryAudioRing.cpp
)

add_executable(virtual_audio_bridge
  src/app/main.mm
  ${COMMON_SOURCES}
)
target_include_directories(virtual_audio_bridge PRIVATE src/common)
target_compile_options(virtual_audio_bridge PRIVATE -Wall -Wextra -Wpedantic)
target_link_libraries(virtual_audio_bridge PRIVATE
  "-framework Foundation"
)

add_library(virtual_audio_driver MODULE
  src/driver/VirtualAudioDriver.cpp
  ${COMMON_SOURCES}
)
target_include_directories(virtual_audio_driver PRIVATE src/common)
target_compile_options(virtual_audio_driver PRIVATE -Wall -Wextra -Wpedantic)
target_link_libraries(virtual_audio_driver PRIVATE
  "-framework CoreAudio"
  "-framework CoreFoundation"
)
set_target_properties(virtual_audio_driver PROPERTIES
  BUNDLE TRUE
  BUNDLE_EXTENSION driver
  PREFIX ""
  OUTPUT_NAME "VirtualAudioBridge"
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/src/driver/Info.plist.in"
)

set(SWIFT_PACKAGE_DIR "${CMAKE_SOURCE_DIR}/swift")
set(SWIFT_BUILD_DIR "${SWIFT_PACKAGE_DIR}/.build/release")
set(ENGINE_HELPER_OUTPUT "${CMAKE_BINARY_DIR}/engine_helper")

add_custom_target(engine_helper_build
  COMMAND env SWIFT_BUILD_DISABLE_SANDBOX=1 CLANG_MODULE_CACHE_PATH=/tmp/stt_tts_bridge_clang_module_cache swift build --package-path "${SWIFT_PACKAGE_DIR}" --product engine_helper -c release
  COMMAND ${CMAKE_COMMAND} -E copy "${SWIFT_BUILD_DIR}/engine_helper" "${ENGINE_HELPER_OUTPUT}"
  COMMENT "Building Swift engine_helper"
)
add_dependencies(virtual_audio_bridge engine_helper_build)

add_custom_target(bridge_companion_build
  COMMAND env SWIFT_BUILD_DISABLE_SANDBOX=1 CLANG_MODULE_CACHE_PATH=/tmp/stt_tts_bridge_clang_module_cache swift build --package-path "${SWIFT_PACKAGE_DIR}" --product bridge_companion -c release
  COMMENT "Building Swift bridge_companion"
)
