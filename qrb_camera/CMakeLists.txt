cmake_minimum_required(VERSION 3.8.2)
project(qrb_camera VERSION 2.0.1)

set(CMAKE_INCLUDE_CURRENT_DIR ON)

if(CMAKE_COMPILER_IS_GNUCXX OR CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  add_compile_options(-Wall -Wextra -Wpedantic)
endif()

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

include_directories(include)

find_package(ament_cmake_auto REQUIRED)
find_package(PkgConfig REQUIRED)
pkg_check_modules(QMMF_CAMERA_METADATA REQUIRED IMPORTED_TARGET qmmf_camera_metadata)

ament_auto_add_library(qrb_camera SHARED
  src/camera_manager.cpp
  src/qmmf_camera.cpp
  src/qmmf_listener.cpp
  src/qmmf_frame.cpp
  src/qmmf_stream.cpp
)

target_link_libraries(qrb_camera
  PRIVATE
#  camera_metadata
    qmmf_recorder_client
    qmmf_camera_metadata
    qmmf_utils
    PkgConfig::QMMF_CAMERA_METADATA
)

set_target_properties(qrb_camera PROPERTIES VERSION ${PROJECT_VERSION} SOVERSION 2)
target_include_directories(qrb_camera PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)

if(BUILD_TESTING)

  ament_auto_add_executable(qrb_camera_test
    test/src/camera_test.cpp
    src/camera_manager.cpp
    src/qmmf_camera.cpp
    src/qmmf_listener.cpp
    src/qmmf_frame.cpp
    src/qmmf_stream.cpp
  )

  target_link_libraries(qrb_camera_test
    # camera_metadata
    qmmf_recorder_client
    qmmf_camera_metadata
    qmmf_utils
  )

endif()

ament_auto_package()
