cmake_minimum_required(VERSION 3.20)
project(iPhoneCameraStream CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(CTest)
if(BUILD_TESTING)
    add_executable(virtual_camera_contract_test ../tests/virtual_camera_contract_test.cpp)
    target_include_directories(virtual_camera_contract_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
    add_test(NAME virtual_camera_contract_test COMMAND virtual_camera_contract_test)
endif()

# ---- FFmpeg (install via vcpkg: `vcpkg install ffmpeg`) ----
find_package(FFMPEG REQUIRED)
# Fallback if find_package above is unavailable:
#   set(FFMPEG_DIR "C:/libs/ffmpeg" CACHE PATH "FFmpeg install prefix")
#   find_library(AVCODEC_LIB avcodec HINTS ${FFMPEG_DIR}/lib)
#   ...

# ---- libusbmuxd (build from https://github.com/libimobiledevice/libusbmuxd) ----
set(USBMUXD_INCLUDE_DIR "" CACHE PATH "libusbmuxd include dir")
set(USBMUXD_LIBRARY "" CACHE FILEPATH "path to usbmuxd.lib")
if(NOT USBMUXD_LIBRARY)
    find_library(USBMUXD_LIBRARY NAMES usbmuxd HINTS ${USBMUXD_INCLUDE_DIR}/../lib)
endif()

set(PROTO_INC ${CMAKE_CURRENT_SOURCE_DIR}/../protocol)

# ============ Receiver (debug / latency measurement) ============
add_executable(receiver receiver.cpp)
target_include_directories(receiver PRIVATE
    ${FFMPEG_INCLUDE_DIRS}
    ${USBMUXD_INCLUDE_DIR}
    ${BASECLASSES_DIR}
    ${PROTO_INC})
target_link_libraries(receiver PRIVATE
    ${FFMPEG_LIBRARIES}
    ${USBMUXD_LIBRARY}
    iphlpapi
    ws2_32)

# The old DirectShow source is retained for research only. It requires the
# documented MSVC/Strmbase build chain and is deliberately not a default target.
option(BUILD_DIRECTSHOW_PROTOTYPE "Build unsupported legacy DirectShow prototype" OFF)
if(BUILD_DIRECTSHOW_PROTOTYPE)
    set(BASECLASSES_DIR "" CACHE PATH "Directory containing streams.h (BaseClasses)")
    if(NOT BASECLASSES_DIR)
        message(FATAL_ERROR "BASECLASSES_DIR is required for the DirectShow prototype")
    endif()
    add_library(iphonecamera MODULE virtual_camera.cpp)
    set_target_properties(iphonecamera PROPERTIES PREFIX "" SUFFIX ".ax")
    target_link_options(iphonecamera PRIVATE "/DEF:${CMAKE_CURRENT_SOURCE_DIR}/iphonecamera.def")
    target_include_directories(iphonecamera PRIVATE
        ${FFMPEG_INCLUDE_DIRS}
        ${USBMUXD_INCLUDE_DIR}
        ${BASECLASSES_DIR}
        ${PROTO_INC})
    target_link_libraries(iphonecamera PRIVATE
        ${FFMPEG_LIBRARIES}
        ${USBMUXD_LIBRARY}
        strmiids
        strmbase
        d3d11
        ws2_32)
endif()
