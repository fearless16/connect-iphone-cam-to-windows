cmake_minimum_required(VERSION 3.25)
project(IPhoneCameraVirtualCamera LANGUAGES CXX)

if(NOT MSVC)
    message(FATAL_ERROR "Media Foundation virtual camera requires MSVC and the Windows 11 SDK")
endif()

add_executable(IPhoneCameraVcamController controller.cpp)
target_compile_features(IPhoneCameraVcamController PRIVATE cxx_std_20)
target_compile_options(IPhoneCameraVcamController PRIVATE /W4 /WX /permissive-)
target_link_libraries(IPhoneCameraVcamController PRIVATE mfplat mf mfsensorgroup mfuuid ole32)

include(CTest)
if(BUILD_TESTING)
    add_executable(gpu_frame_transport_contract_test
        ../../tests/gpu_frame_transport_contract_test.cpp)
    target_compile_features(gpu_frame_transport_contract_test PRIVATE cxx_std_20)
    target_include_directories(gpu_frame_transport_contract_test PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR})
    add_test(NAME gpu_frame_transport_contract_test
        COMMAND gpu_frame_transport_contract_test)
endif()
