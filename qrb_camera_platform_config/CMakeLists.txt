# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
cmake_minimum_required(VERSION 3.16)
project(qrb_camera_platform_config VERSION 0.1.0 LANGUAGES NONE)

# Platform configuration candidates of the camera domain: one file per machine and OS type,
# named <machine>-<platform>-camera.config.yaml. platform-detect (from plugin_discovery) links
# the one matching this machine into /etc/plugin_discovery/platform.d/ on the first boot;
# the postinst / postrm of the Debian package rerun it. No code; does not need plugin_discovery
# to build.
#
# Temporary home: the same files are in plugin_discovery (branch platform-config, camera/),
# package plugin-discovery-platform-config. Both packages install the same file names, so
# install only one of them (see DESIGN.md 8.3).

# platform-detect only reads /usr/share/plugin_discovery/platforms.d (plugin-discovery is
# installed to /usr), while ros-jazzy-* packages use the prefix /opt/ros/jazzy: the Debian
# build passes the absolute directory. The default (relative to the prefix) suits local
# builds and tests.
set(QRB_CAMERA_CANDIDATES_DIR "share/plugin_discovery/platforms.d"
  CACHE STRING "Where to install the platform configuration candidates")

install(FILES
  config/QCS9075-Ubuntu-camera.config.yaml    # IQ9:  qmmf
  config/QAM8797P-Ubuntu-camera.config.yaml   # IQ10: qcarcam
  DESTINATION ${QRB_CAMERA_CANDIDATES_DIR})
