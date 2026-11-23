# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
cmake_minimum_required(VERSION 3.16)
project(camera_interface VERSION 1.0.0 LANGUAGES CXX)

# Header-only: the camera domain interface (ICameraBackend, declared to plugin_discovery
# as domain "camera" 1.0) and its data types. No vendor SDK, no ROS.

include(GNUInstallDirs)
include(CMakePackageConfigHelpers)

find_package(plugin_discovery 0.3 REQUIRED)

add_library(camera_interface INTERFACE)
add_library(camera_interface::camera_interface ALIAS camera_interface)
target_compile_features(camera_interface INTERFACE cxx_std_17)
target_include_directories(camera_interface INTERFACE
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>)
target_link_libraries(camera_interface INTERFACE plugin_discovery::plugin_discovery)

install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(TARGETS camera_interface EXPORT camera_interfaceTargets)
install(EXPORT camera_interfaceTargets NAMESPACE camera_interface::
  DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/camera_interface)

configure_package_config_file(cmake/camera_interfaceConfig.cmake.in
  ${CMAKE_CURRENT_BINARY_DIR}/camera_interfaceConfig.cmake
  INSTALL_DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/camera_interface)
write_basic_package_version_file(${CMAKE_CURRENT_BINARY_DIR}/camera_interfaceConfigVersion.cmake
  COMPATIBILITY SameMajorVersion ARCH_INDEPENDENT)
install(FILES
  ${CMAKE_CURRENT_BINARY_DIR}/camera_interfaceConfig.cmake
  ${CMAKE_CURRENT_BINARY_DIR}/camera_interfaceConfigVersion.cmake
  DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/camera_interface)
