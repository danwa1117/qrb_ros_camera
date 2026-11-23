# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
cmake_minimum_required(VERSION 3.16)
project(qrb_camera VERSION 3.0.0 LANGUAGES CXX)

# CameraManager: loads the camera backends through plugin_discovery and manages the cameras
# opened on them. Links no backend and no vendor SDK. No ROS.

include(GNUInstallDirs)
include(CMakePackageConfigHelpers)
include(CTest)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

find_package(plugin_discovery 0.3 REQUIRED)
find_package(camera_interface 1.0 REQUIRED)

# Where this prefix installs the camera backends' manifests: the default search directory.
plugin_discovery_plugin_dir(camera QRB_CAMERA_PLUGIN_DIR)

add_library(qrb_camera SHARED src/camera_manager.cpp)
add_library(qrb_camera::qrb_camera ALIAS qrb_camera)
target_include_directories(qrb_camera
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>
  PRIVATE src)
target_link_libraries(qrb_camera PUBLIC
  camera_interface::camera_interface plugin_discovery::plugin_discovery)
target_compile_definitions(qrb_camera PRIVATE QRB_CAMERA_PLUGIN_DIR="${QRB_CAMERA_PLUGIN_DIR}")
target_compile_options(qrb_camera PRIVATE -Wall -Wextra -Wpedantic)
set_target_properties(qrb_camera PROPERTIES VERSION ${PROJECT_VERSION} SOVERSION 3)

install(TARGETS qrb_camera EXPORT qrb_cameraTargets
  LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR})
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(EXPORT qrb_cameraTargets NAMESPACE qrb_camera::
  DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/qrb_camera)

configure_package_config_file(cmake/qrb_cameraConfig.cmake.in
  ${CMAKE_CURRENT_BINARY_DIR}/qrb_cameraConfig.cmake
  INSTALL_DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/qrb_camera)
write_basic_package_version_file(${CMAKE_CURRENT_BINARY_DIR}/qrb_cameraConfigVersion.cmake
  COMPATIBILITY SameMajorVersion)
install(FILES
  ${CMAKE_CURRENT_BINARY_DIR}/qrb_cameraConfig.cmake
  ${CMAKE_CURRENT_BINARY_DIR}/qrb_cameraConfigVersion.cmake
  DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/qrb_camera)

if(BUILD_TESTING)
  add_subdirectory(test)
endif()
