cmake_minimum_required(VERSION 3.16)
project(watchvad LANGUAGES C CXX)
set(CMAKE_C_STANDARD 99)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Pinned portable WebRTC sources. No network access during a DevEco build.
file(GLOB VAD_SOURCES CONFIGURE_DEPENDS
    third_party/webrtc/common_audio/vad/*.c
    third_party/webrtc/common_audio/signal_processing/*.c)
add_library(webrtc_vad STATIC ${VAD_SOURCES} third_party/webrtc/rtc_base/checks.cc)
target_include_directories(webrtc_vad PUBLIC third_party)
target_compile_definitions(webrtc_vad PRIVATE WEBRTC_POSIX)

option(WATCH_VAD_HOST_TEST "Build Node-API bridge and regression tests on Linux" OFF)
add_library(watchvad SHARED napi_vad.cpp)
target_link_libraries(watchvad PRIVATE webrtc_vad)
if(WATCH_VAD_HOST_TEST)
    if(NOT NODE_INCLUDE_DIR)
        message(FATAL_ERROR "Set NODE_INCLUDE_DIR to the directory containing node_api.h")
    endif()
    target_include_directories(watchvad PRIVATE "${NODE_INCLUDE_DIR}")
    target_compile_definitions(watchvad PRIVATE WATCH_VAD_HOST_TEST)
    set_target_properties(watchvad PROPERTIES PREFIX "" SUFFIX ".node")
    add_executable(vad_regression ../../../../tests/native/vad_regression.cpp)
    target_link_libraries(vad_regression PRIVATE webrtc_vad)
else()
    target_link_libraries(watchvad PRIVATE libace_napi.z.so)
endif()
