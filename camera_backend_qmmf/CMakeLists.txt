# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
cmake_minimum_required(VERSION 3.16)
project(camera_backend_qmmf VERSION 1.0.0 LANGUAGES CXX)

# QMMF/CamX camera backend (IQ9) for plugin_discovery. Installs
#   lib/camera/libcamera_backend_qmmf.so
#   share/camera/plugins/camera_backend_qmmf.plugin.yaml
# Without the QMMF SDK nothing is built (or, with -DREQUIRE_ALL_BACKENDS=ON, configuring fails).

include(GNUInstallDirs)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(REQUIRE_ALL_BACKENDS "Fail instead of skipping this backend when its vendor SDK is missing" OFF)

find_package(plugin_discovery 0.3 REQUIRED)
find_package(camera_interface 1.0 REQUIRED)

find_path(QMMF_INCLUDE_DIR qmmf-sdk/qmmf_recorder.h)
set(qmmf_libs "")
set(qmmf_missing "")
foreach(lib camera_metadata qmmf_recorder_client qmmf_camera_metadata qmmf_utils)
  find_library(QMMF_LIB_${lib} ${lib})
  if(QMMF_LIB_${lib})
    list(APPEND qmmf_libs ${QMMF_LIB_${lib}})
  else()
    list(APPEND qmmf_missing ${lib})
  endif()
endforeach()

# The original IQ9 build used no -I for the SDK: accept a header the compiler finds itself.
set(qmmf_header_ok FALSE)
if(QMMF_INCLUDE_DIR)
  set(qmmf_header_ok TRUE)
else()
  include(CheckIncludeFileCXX)
  check_include_file_cxx(qmmf-sdk/qmmf_recorder.h QMMF_H_IN_DEFAULT_PATH)
  if(QMMF_H_IN_DEFAULT_PATH)
    set(qmmf_header_ok TRUE)
    set(QMMF_INCLUDE_DIR "")
  endif()
endif()

if(NOT qmmf_header_ok OR qmmf_missing)
  set(reason "QMMF SDK not found (qmmf-sdk/qmmf_recorder.h: ${QMMF_INCLUDE_DIR}; missing libraries: ${qmmf_missing}). If the header is installed elsewhere, pass -DQMMF_INCLUDE_DIR=<dir>")
  if(REQUIRE_ALL_BACKENDS)
    message(FATAL_ERROR "camera backend 'qmmf': ${reason}")
  endif()
  message(WARNING "camera backend 'qmmf' skipped: ${reason}")
  return()
endif()

add_library(camera_backend_qmmf SHARED
  src/qmmf_backend.cpp
  src/qmmf_camera.cpp
  src/qmmf_frame.cpp
  src/qmmf_stream.cpp)
target_include_directories(camera_backend_qmmf PRIVATE src ${QMMF_INCLUDE_DIR})
target_link_libraries(camera_backend_qmmf PRIVATE camera_interface::camera_interface ${qmmf_libs})
target_compile_options(camera_backend_qmmf PRIVATE -Wall -Wextra -Wpedantic)

plugin_discovery_add_plugin(
  TARGET camera_backend_qmmf
  DOMAIN camera
  NAME camera/QMMFCamera
  CLASS qrb_camera::QMMFBackend
  BASE qrb_camera::ICameraBackend
  BACKEND qmmf
  ORIGIN qcom
  CAPABILITIES unlisted_ids)
