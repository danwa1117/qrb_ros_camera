# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
cmake_minimum_required(VERSION 3.16)
project(camera_backend_qcarcam VERSION 1.0.0 LANGUAGES CXX)

# QCarCam camera backend (IQ10) for plugin_discovery. Installs
#   lib/camera/libcamera_backend_qcarcam.so
#   share/camera/plugins/camera_backend_qcarcam.plugin.yaml
# Without the QCarCam SDK (camera-qcx-dev) nothing is built (or, with
# -DREQUIRE_ALL_BACKENDS=ON, configuring fails).

include(GNUInstallDirs)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(REQUIRE_ALL_BACKENDS "Fail instead of skipping this backend when its vendor SDK is missing" OFF)

find_package(plugin_discovery 0.3 REQUIRED)
find_package(camera_interface 1.0 REQUIRED)
find_package(Threads REQUIRED)

find_path(QCARCAM_INCLUDE_DIR qcarcam.h PATH_SUFFIXES qcarcam qcx camera-qcx)
find_library(QCX_CLIENT_LIB qcxclient)
find_library(QCX_OSAL_LIB qcxosal)

# The original IQ10 build just did #include <qcarcam.h> with no -I: the header may sit in a
# directory the compiler searches but find_path() does not. Accept that too.
set(qcarcam_header_ok FALSE)
if(QCARCAM_INCLUDE_DIR)
  set(qcarcam_header_ok TRUE)
else()
  include(CheckIncludeFileCXX)
  check_include_file_cxx(qcarcam.h QCARCAM_H_IN_DEFAULT_PATH)
  if(QCARCAM_H_IN_DEFAULT_PATH)
    set(qcarcam_header_ok TRUE)
    set(QCARCAM_INCLUDE_DIR "")
  endif()
endif()

if(NOT qcarcam_header_ok OR NOT QCX_CLIENT_LIB OR NOT QCX_OSAL_LIB)
  set(reason "QCarCam SDK not found (qcarcam.h: ${QCARCAM_INCLUDE_DIR}; qcxclient: ${QCX_CLIENT_LIB}; qcxosal: ${QCX_OSAL_LIB}). If qcarcam.h is installed elsewhere, pass -DQCARCAM_INCLUDE_DIR=<dir>")
  if(REQUIRE_ALL_BACKENDS)
    message(FATAL_ERROR "camera backend 'qcarcam': ${reason}")
  endif()
  message(WARNING "camera backend 'qcarcam' skipped: ${reason}")
  return()
endif()

if(NOT CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm)")
  message(WARNING "camera backend 'qcarcam': QTimer timestamps need an ARM target "
    "(CMAKE_SYSTEM_PROCESSOR is ${CMAKE_SYSTEM_PROCESSOR})")
endif()

add_library(camera_backend_qcarcam SHARED
  src/qcarcam_backend.cpp
  src/qcarcam_camera.cpp
  src/qcarcam_stream.cpp)
target_include_directories(camera_backend_qcarcam PRIVATE src ${QCARCAM_INCLUDE_DIR})
target_link_libraries(camera_backend_qcarcam PRIVATE
  camera_interface::camera_interface ${QCX_CLIENT_LIB} ${QCX_OSAL_LIB} Threads::Threads)
target_compile_options(camera_backend_qcarcam PRIVATE -Wall -Wextra -Wpedantic)

plugin_discovery_add_plugin(
  TARGET camera_backend_qcarcam
  DOMAIN camera
  NAME camera/QCarCamCamera
  CLASS qrb_camera::QCarCamBackend
  BASE qrb_camera::ICameraBackend
  BACKEND qcarcam
  ORIGIN qcom)
