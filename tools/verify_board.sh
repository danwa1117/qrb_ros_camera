#!/usr/bin/env bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
#
# On-board verification of qrb_ros_camera_pd (VERIFY.md, sections 0-6), automated.
# Run ON THE BOARD from the workspace that holds plugin_discovery/ and qrb_ros_camera_pd/:
#
#   cd <ws> && bash qrb_ros_camera_pd/tools/verify_board.sh --board iq9
#   cd <ws> && bash qrb_ros_camera_pd/tools/verify_board.sh --board iq10 --camera-id 5
#
# Options:
#   --board iq9|iq10     required
#   --camera-id N        default 0 (IQ9); IQ10: a QCarCam inputId, needed for steps 5-6 only
#   --from STEP          start at step 0..6 (earlier steps are assumed done)
#   --to STEP            stop after step 0..6, e.g. --to 4: everything before running the node
#   --only STEP          run one step only
#   --yes                do not ask before the steps that change the system (1 and 4)
#   --run-seconds N      how long each node run lasts, default 25
#
# What changes the system (asked before, unless --yes):
#   step 1: sudo dpkg -i plugin-discovery_*.deb   (not apt: no needrestart, no other upgrades)
#   step 4: sudo cmake --install <platform config> --prefix /usr; sudo platform-detect --force
# Nothing else is installed, removed or restarted. A baseline of failed systemd units is
# taken in step 0 and compared after steps 1 and 4.
#
# Output: verify_logs/<time>/ (one log per step and per node run) and a .tar.gz of it,
# plus a PASS/FAIL summary at the end.

set -u -o pipefail

# ---------------------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------------------
BOARD=""
CAMERA_ID=""
FROM=0
TO=6
ONLY=""
YES=0
RUN_SECONDS=25

usage() { sed -n '5,23p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --board) BOARD="${2:-}"; shift 2 ;;
    --camera-id) CAMERA_ID="${2:-}"; shift 2 ;;
    --from) FROM="${2:-}"; shift 2 ;;
    --to) TO="${2:-}"; shift 2 ;;
    --only) ONLY="${2:-}"; shift 2 ;;
    --yes) YES=1; shift ;;
    --run-seconds) RUN_SECONDS="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1"; usage ;;
  esac
done

case "$BOARD" in
  iq9)
    BACKEND=qmmf; OTHER_BACKEND=qcarcam
    BUILD_PKG=camera_backend_qmmf; SKIP_PKG=camera_backend_qcarcam
    EXPECTED_MACHINE=QCS9075
    CAMERA_ID="${CAMERA_ID:-0}" ;;
  iq10)
    BACKEND=qcarcam; OTHER_BACKEND=qmmf
    BUILD_PKG=camera_backend_qcarcam; SKIP_PKG=camera_backend_qmmf
    EXPECTED_MACHINE=QAM8797P ;;
  *) echo "--board iq9|iq10 is required"; usage ;;
esac

# The camera id is only used when the node runs (steps 5 and 6).
LAST=$TO; [ -n "$ONLY" ] && LAST=$ONLY
if [ "$BOARD" = iq10 ] && [ -z "$CAMERA_ID" ] && [ "$LAST" -ge 5 ]; then
  echo "--camera-id is required for iq10 steps 5 and 6 (a QCarCam inputId; step 5 lists them if unsure)"
  exit 2
fi
CAMERA_ID="${CAMERA_ID:--}"

WS="$(pwd)"
PD_SRC="$WS/plugin_discovery"
REPO="$WS/qrb_ros_camera_pd"
if [ ! -d "$PD_SRC" ] || [ ! -d "$REPO" ]; then
  echo "run this from the workspace that holds plugin_discovery/ and qrb_ros_camera_pd/ (now: $WS)"
  exit 2
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$WS/verify_logs/$BOARD-$STAMP"
mkdir -p "$LOG_DIR"
BASELINE="$WS/verify_logs/baseline_failed_units.txt"
SUMMARY="$LOG_DIR/summary.txt"
CANDIDATES=/usr/share/plugin_discovery/platforms.d
PLATFORM_LINK=/etc/plugin_discovery/platform.d/camera.config.yaml

# Variables of plugin_discovery that would change what the tests see.
unset PLUGIN_DISCOVERY_PATH PLUGIN_DISCOVERY_CONFIG_PATH PLUGIN_DISCOVERY_BACKEND_CAMERA

# ---------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------
if [ -t 1 ]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else G=; R=; Y=; B=; N=; fi
FAILS=0

log()   { echo "$*" | tee -a "$SUMMARY"; }
title() { echo; log "${B}=== $* ===${N}"; }
pass()  { log "  ${G}PASS${N}  $*"; }
fail()  { log "  ${R}FAIL${N}  $*"; FAILS=$((FAILS + 1)); }
warn()  { log "  ${Y}WARN${N}  $*"; }
info()  { log "        $*"; }

# check <description> <command...>: PASS if the command succeeds.
check() { local d="$1"; shift; if "$@" >>"$LOG_DIR/checks.log" 2>&1; then pass "$d"; else fail "$d"; fi; }

# A step that fails stops the script: later steps depend on it.
stop() {
  log ""
  log "${R}Stopped in step $CURRENT_STEP: $*${N}"
  finish 1
}

want_step() {
  local s="$1"
  if [ -n "$ONLY" ]; then [ "$s" = "$ONLY" ]; else [ "$s" -ge "$FROM" ] && [ "$s" -le "$TO" ]; fi
}

confirm() {
  [ "$YES" = 1 ] && return 0
  echo
  echo "${Y}About to change the system:${N}"
  printf '  %s\n' "$@"
  read -r -p "Continue? [y/N] " a
  [ "$a" = y ] || [ "$a" = Y ]
}

ros_env() {
  # setup.bash scripts reference unset variables
  set +u
  # shellcheck disable=SC1091
  source /opt/ros/jazzy/setup.bash
  if [ -f "$WS/install/setup.bash" ]; then
    # shellcheck disable=SC1091
    source "$WS/install/setup.bash"
  fi
  set -u
}

failed_units() { systemctl --failed --no-pager --plain --no-legend | awk '{print $1}' | sort; }

compare_baseline() {
  if [ ! -f "$BASELINE" ]; then warn "no baseline (step 0 not run): cannot compare failed units"; return; fi
  local now new
  now="$(failed_units)"
  new="$(comm -13 "$BASELINE" <(echo "$now") | sed '/^$/d')"
  if [ -z "$new" ]; then
    pass "no new failed systemd unit since the baseline"
  else
    fail "new failed systemd units since the baseline: $(echo "$new" | tr '\n' ' ')"
  fi
}

# run_node <name> <seconds> <env assignments or ""> <launch arguments...>
# Runs the node for <seconds>, then stops it with SIGINT. Log: $LOG_DIR/run_<name>.log
run_node() {
  local name="$1" secs="$2" envs="$3"; shift 3
  local out="$LOG_DIR/run_$name.log"
  info "run '$name': ${envs:+$envs }ros2 launch qrb_ros_camera qrb_ros_camera_launch.py $*  (${secs}s)"
  # shellcheck disable=SC2086
  env $envs timeout -s INT -k 10 "$secs" \
    ros2 launch qrb_ros_camera qrb_ros_camera_launch.py "$@" >"$out" 2>&1
  RUN_LOG="$out"
}

has()   { grep -qE -- "$1" "$RUN_LOG"; }
# Real crashes only: a node stopped by `timeout` may also be reported as "process has died".
crash() { grep -qE 'Segmentation fault|core dumped|terminate called|exit code -11|exit code -6' "$RUN_LOG"; }

expect_frames() {
  local what="$1"
  if has '\[CameraManager\]: started camera' && has 'Fps: '; then pass "$what: frames received"
  else fail "$what: no frames (see $(basename "$RUN_LOG"))"; fi
  if crash; then fail "$what: crash or unclean exit in $(basename "$RUN_LOG")"; fi
}

expect_refused() {
  local what="$1" pattern="$2"
  if has "$pattern" && has 'Component constructor threw an exception'; then pass "$what: refused as expected"
  else fail "$what: expected '$pattern' (see $(basename "$RUN_LOG"))"; fi
  if crash; then fail "$what: crash in $(basename "$RUN_LOG")"; fi
}

finish() {
  local code="${1:-0}"
  echo
  log "${B}=== Summary ($BOARD, camera_id $CAMERA_ID) ===${N}"
  if [ "$FAILS" -eq 0 ] && [ "$code" -eq 0 ]; then log "${G}all checks passed${N}"; else log "${R}$FAILS check(s) failed${N}"; fi
  tar -C "$WS/verify_logs" -czf "$LOG_DIR.tar.gz" "$(basename "$LOG_DIR")" 2>/dev/null
  log "logs: $LOG_DIR"
  log "send: $LOG_DIR.tar.gz"
  exit $(( code != 0 || FAILS != 0 ))
}

CURRENT_STEP=-

# ---------------------------------------------------------------------------------------
# Step 0: preconditions (read only) and baseline
# ---------------------------------------------------------------------------------------
if want_step 0; then
  CURRENT_STEP=0
  title "0. preconditions ($BOARD)"
  {
    echo "date: $(date -Is)"; echo "board: $BOARD"; uname -a
    head -3 /etc/os-release; echo "machine: $(cat /sys/devices/soc0/machine 2>/dev/null)"
  } >"$LOG_DIR/environment.txt"

  check "Ubuntu" grep -q '^ID=ubuntu' /etc/os-release
  check "ROS 2 Jazzy" test -f /opt/ros/jazzy/setup.bash
  check "colcon" command -v colcon
  check "cmake" command -v cmake
  check "C++ compiler (g++) and make: build-essential" sh -c 'command -v g++ && command -v make'
  check "yaml-cpp exports yaml-cpp::yaml-cpp (0.8)" \
    grep -rqs 'yaml-cpp::yaml-cpp' /usr/lib/aarch64-linux-gnu/cmake/yaml-cpp/
  check "qrb_ros_transport_image_type installed" \
    sh -c 'dpkg -l | grep -q qrb-ros-transport-image-type'

  if [ "$BOARD" = iq9 ]; then
    check "QMMF header qmmf-sdk/qmmf_recorder.h" \
      sh -c 'test -f /usr/include/qmmf-sdk/qmmf_recorder.h || echo "#include <qmmf-sdk/qmmf_recorder.h>" | g++ -std=c++17 -fsyntax-only -x c++ - '
    for lib in camera_metadata qmmf_recorder_client qmmf_camera_metadata qmmf_utils; do
      check "QMMF library lib$lib.so" sh -c "ls /usr/lib/aarch64-linux-gnu/lib$lib.so* /usr/lib/lib$lib.so* 2>/dev/null | grep -q ."
    done
    systemctl list-units --all --no-pager --plain | grep -iE 'qmmf|camera|cam-server' \
      >"$LOG_DIR/camera_services.txt" 2>&1 || true
    info "camera-related units: $LOG_DIR/camera_services.txt"
  else
    check "QCarCam header qcarcam.h" \
      sh -c 'find /usr/include -name qcarcam.h | grep -q . || echo "#include <qcarcam.h>" | g++ -std=c++17 -fsyntax-only -x c++ -'
    for lib in qcxclient qcxosal; do
      check "QCarCam library lib$lib.so" sh -c "ls /usr/lib/aarch64-linux-gnu/lib$lib.so* 2>/dev/null | grep -q ."
    done
    check "qcx_server.service active" systemctl is-active --quiet qcx_server.service
    check "qcxserver process running" pgrep -x qcxserver
  fi

  MACHINE="$(cat /sys/devices/soc0/machine 2>/dev/null)"
  if [ "$(echo "$MACHINE" | tr a-z A-Z)" = "$EXPECTED_MACHINE" ]; then
    pass "machine is $MACHINE (C1)"
  else
    fail "machine is '$MACHINE', expected $EXPECTED_MACHINE (C1)"
    info "rename qrb_ros_camera_pd/qrb_camera_platform_config/config/$EXPECTED_MACHINE-Ubuntu-camera.config.yaml"
    info "to $MACHINE-Ubuntu-camera.config.yaml (and in its CMakeLists.txt), then rerun"
  fi

  failed_units >"$BASELINE"
  info "baseline of failed units ($(wc -l <"$BASELINE")): $BASELINE"
  sed 's/^/          /' "$BASELINE" | tee -a "$SUMMARY"
  [ "$FAILS" -eq 0 ] || stop "preconditions not met"
fi

# ---------------------------------------------------------------------------------------
# Step 1: plugin_discovery (build, test, package, dpkg -i)
# ---------------------------------------------------------------------------------------
if want_step 1; then
  CURRENT_STEP=1
  title "1. plugin_discovery"
  L="$LOG_DIR/step1_plugin_discovery.log"
  (
    cd "$PD_SRC" &&
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DPLUGIN_LOADER_BUILD_TESTS=ON &&
    cmake --build build -j"$(nproc)"
  ) >"$L" 2>&1 || stop "build failed, see $L"
  pass "built"
  if "$PD_SRC/build/test/registry_test" "$PD_SRC/build/test/backends" 2>>"$L" | tail -1 | grep -q 'all passed'; then
    pass "registry_test"
  else
    stop "registry_test failed, see $L"
  fi
  (cd "$PD_SRC/build" && cpack -G DEB) >>"$L" 2>&1 || stop "cpack failed, see $L"
  DEB="$(ls -t "$PD_SRC"/build/plugin-discovery_*.deb | head -1)"
  pass "packaged $(basename "$DEB")"

  INSTALLED_LIB="$(dpkg -L plugin-discovery 2>/dev/null | grep -E '/libplugin_discovery\.so$' | head -1)"
  if [ -n "$INSTALLED_LIB" ] && \
     [ "$(dpkg-query -W -f='${Version}' plugin-discovery)" = "$(dpkg-deb -f "$DEB" Version)" ] && \
     cmp -s "$INSTALLED_LIB" "$PD_SRC/build/libplugin_discovery.so"; then
    info "plugin-discovery $(dpkg-query -W -f='${Version}' plugin-discovery) already installed and identical: not reinstalled"
  else
    confirm "sudo dpkg -i $DEB" || stop "not confirmed"
    sudo dpkg -i "$DEB" >>"$L" 2>&1 || stop "dpkg -i failed (dependencies?), see $L. Do not run apt -f install; send the log"
    pass "installed with dpkg -i"
  fi
  check "platform-detect in /usr/bin" test -x /usr/bin/platform-detect
  check "pluginlib-detect in /usr/bin" test -x /usr/bin/pluginlib-detect
  check "platform-detect service enabled" systemctl is-enabled --quiet plugin-discovery-platform-detect.service
  compare_baseline
fi

# ---------------------------------------------------------------------------------------
# Step 2: build this repository (colcon)
# ---------------------------------------------------------------------------------------
if want_step 2; then
  CURRENT_STEP=2
  # The plain build, as anyone would run it: no backend is named. Each backend package builds
  # when its vendor SDK is present and skips itself (a CMake warning) otherwise.
  title "2. colcon build (no backend named)"
  L="$LOG_DIR/step2_colcon_build.log"
  ros_env
  (
    cd "$WS" &&
    # REQUIRE_ALL_BACKENDS=OFF is the default; given explicitly only to override a value
    # cached by an earlier build with ON.
    colcon build --base-paths qrb_ros_camera_pd --cmake-args -DBUILD_TESTING=ON -DREQUIRE_ALL_BACKENDS=OFF
  ) >"$L" 2>&1
  rc=$?
  for f in "$WS"/log/latest_build/*/stdout_stderr.log; do cp "$f" "$LOG_DIR/build_$(basename "$(dirname "$f")").log" 2>/dev/null; done
  grep -E '^(Finished|Failed|Aborted)|^Summary|packages? (failed|aborted)' "$L" | sed 's/^/          /' | tee -a "$SUMMARY"
  if [ $rc -ne 0 ]; then
    stop "colcon build failed, see $L and $LOG_DIR/build_*.log"
  fi
  pass "all packages built"
  ros_env
  # This board's backend must have been built (its SDK is here) ...
  MANIFEST="$WS/install/$BUILD_PKG/share/camera/plugins/$BUILD_PKG.plugin.yaml"
  if [ -f "$MANIFEST" ]; then
    pass "$BUILD_PKG built (its SDK is present)"
    cp "$MANIFEST" "$LOG_DIR/"
  else
    fail "$BUILD_PKG was skipped although this is $BOARD: its SDK was not found (see build_$BUILD_PKG.log)"
  fi
  # ... and the other board's backend skipped itself without failing the build.
  if [ ! -f "$WS/install/$SKIP_PKG/share/camera/plugins/$SKIP_PKG.plugin.yaml" ] && \
     grep -q "camera backend '$OTHER_BACKEND' skipped" "$LOG_DIR/build_$SKIP_PKG.log" 2>/dev/null; then
    pass "$SKIP_PKG skipped itself (no SDK on this board), build not failed"
  elif [ -f "$WS/install/$SKIP_PKG/share/camera/plugins/$SKIP_PKG.plugin.yaml" ]; then
    info "$SKIP_PKG was built too: its SDK is also present on this board"
  else
    warn "$SKIP_PKG: no 'skipped' message found (see build_$SKIP_PKG.log)"
  fi
  [ "$FAILS" -eq 0 ] || stop "this board's backend was not built"
fi

# ---------------------------------------------------------------------------------------
# Step 3: manager unit test
# ---------------------------------------------------------------------------------------
if want_step 3; then
  CURRENT_STEP=3
  title "3. camera_manager_test"
  ros_env
  L="$LOG_DIR/step3_camera_manager_test.log"
  "$WS/build/qrb_camera/test/camera_manager_test" >"$L" 2>&1
  RESULT="$(grep -E '^(all passed|FAILED)' "$L" | tail -1)"
  if [ -n "$RESULT" ] && [ "${RESULT#all passed}" != "$RESULT" ]; then pass "$RESULT"; else fail "camera_manager_test: ${RESULT:-no result}, see $L"; fi
fi

# ---------------------------------------------------------------------------------------
# Step 4: platform configuration (install files, platform-detect)
# ---------------------------------------------------------------------------------------
if want_step 4; then
  CURRENT_STEP=4
  title "4. platform configuration"
  L="$LOG_DIR/step4_platform_config.log"
  confirm "sudo cmake --install $WS/build/qrb_camera_platform_config --prefix /usr   (-> $CANDIDATES)" \
          "sudo platform-detect --force   (-> $PLATFORM_LINK)" || stop "not confirmed"
  {
    sudo cmake --install "$WS/build/qrb_camera_platform_config" --prefix /usr &&
    sudo platform-detect --force
  } >"$L" 2>&1 || stop "install / platform-detect failed, see $L"
  sed 's/^/          /' "$L" | grep -E 'Installing|Up-to-date|platform-detect' | tee -a "$SUMMARY"

  check "candidate $EXPECTED_MACHINE-Ubuntu-camera.config.yaml installed" test -f "$CANDIDATES/$EXPECTED_MACHINE-Ubuntu-camera.config.yaml"
  TARGET="$(readlink -f "$PLATFORM_LINK" 2>/dev/null)"
  if [ "$(basename "$TARGET" 2>/dev/null)" = "$EXPECTED_MACHINE-Ubuntu-camera.config.yaml" ]; then
    pass "camera.config.yaml -> $TARGET"
  else
    fail "camera.config.yaml -> '${TARGET:-missing}', expected .../$EXPECTED_MACHINE-Ubuntu-camera.config.yaml"
  fi
  cat /var/lib/plugin_discovery/platform-detect.done >>"$L" 2>&1

  ros_env
  PLUGIN_DISCOVERY_PATH="$(ls -d "$WS"/install/*/share/camera/plugins 2>/dev/null | paste -sd:)" \
    pluginlib-detect -d camera >"$LOG_DIR/pluginlib-detect.txt" 2>&1
  sed 's/^/          /' "$LOG_DIR/pluginlib-detect.txt" | sed -n '/^ *Domain camera/,$p' | tee -a "$SUMMARY"
  if grep -qE "^ *1\. $BACKEND +\[platform\]" "$LOG_DIR/pluginlib-detect.txt" && \
     ! grep -A1 -E "^ *1\. $BACKEND" "$LOG_DIR/pluginlib-detect.txt" | grep -q 'not installed'; then
    pass "default backend is $BACKEND, installed"
  else
    fail "pluginlib-detect does not show '1. $BACKEND [platform]' installed (see pluginlib-detect.txt)"
  fi
  compare_baseline
fi

# ---------------------------------------------------------------------------------------
# Step 5: node, normal path
# ---------------------------------------------------------------------------------------
if want_step 5; then
  CURRENT_STEP=5
  title "5. node: normal path (camera_id $CAMERA_ID, ${RUN_SECONDS}s per run)"
  ros_env
  if [ "$BOARD" = iq10 ] && ! systemctl is-active --quiet qcx_server.service; then
    stop "qcx_server.service is not active: the camera cannot work (not a problem of this repository)"
  fi

  # The timestamp is checked from a second process while the node runs.
  TOPIC="/cam${CAMERA_ID}_stream1_camera_info"
  (
    sleep $((RUN_SECONDS / 2))
    s="$(timeout 8 ros2 topic echo --once "$TOPIC" --field header.stamp.sec 2>/dev/null | head -1)"
    echo "$s $(date +%s)" >"$LOG_DIR/stamp_check.txt"
  ) &
  STAMP_PID=$!

  run_node normal "$RUN_SECONDS" "" camera_id:="$CAMERA_ID" enable_test_node:=true
  wait "$STAMP_PID" 2>/dev/null

  grep -E 'camera backends|created camera|on backend|camera clock|started camera|init success|Fps:|skipped|ERROR' "$RUN_LOG" \
    | head -20 | sed 's/^/          /' | tee -a "$SUMMARY"

  if has "camera backends \(config\): $BACKEND "; then pass "backend $BACKEND loaded from the platform configuration"
  else fail "'camera backends (config): $BACKEND ...' missing"; fi
  expect_frames "normal run"

  FPS="$(grep -oE 'Fps: [0-9.]+' "$RUN_LOG" | awk '{print $2}' | tail -1)"
  if [ -n "$FPS" ]; then
    if awk -v f="$FPS" 'BEGIN{exit !(f > 20 && f < 40)}'; then pass "fps $FPS (expected ~30)"; else fail "fps $FPS (expected ~30)"; fi
  fi
  LAT="$(grep -oE 'latency -?[0-9]+ us' "$RUN_LOG" | awk '{print $2}' | tail -1)"
  if [ -n "$LAT" ]; then
    if [ "$LAT" -gt 0 ] && [ "$LAT" -lt 1000000 ]; then pass "latency ${LAT} us (positive, below 1 s: clock offset sane)"
    else fail "latency ${LAT} us: the time offset is wrong (clock domain)"; fi
  fi
  # The offset is recomputed every second, so the latency must not creep: before that fix it
  # grew by ~33 us/s on IQ10 (system clock slewed by time sync, QTimer not).
  LATS="$(grep -E '\[camera_node\]: name:' "$RUN_LOG" | grep -oE 'latency -?[0-9]+ us' | awk '{print $2}')"
  if [ "$(echo "$LATS" | sed '/^$/d' | wc -l)" -ge 3 ]; then
    FIRST_LAT="$(echo "$LATS" | sed -n 2p)"   # the first window includes the start-up
    LAST_LAT="$(echo "$LATS" | tail -1)"
    DRIFT=$(( LAST_LAT - FIRST_LAT ))
    if [ "${DRIFT#-}" -le 150 ]; then pass "latency stable: ${FIRST_LAT} -> ${LAST_LAT} us (time offset follows the camera clock)"
    else fail "latency drifts: ${FIRST_LAT} -> ${LAST_LAT} us (time offset not following the camera clock)"; fi
  else
    warn "not enough fps lines to check that the latency is stable (use --run-seconds 25 or more)"
  fi
  if has 'time offset changed by'; then warn "system clock stepped during the run: $(grep -m1 'time offset changed by' "$RUN_LOG" | sed 's/.*time offset/time offset/')"; fi
  STAMP_SEC=; NOW_SEC=
  [ -f "$LOG_DIR/stamp_check.txt" ] && read -r STAMP_SEC NOW_SEC <"$LOG_DIR/stamp_check.txt"
  if [ -n "${STAMP_SEC:-}" ] && [ -n "${NOW_SEC:-}" ]; then
    D=$(( STAMP_SEC > NOW_SEC ? STAMP_SEC - NOW_SEC : NOW_SEC - STAMP_SEC ))
    if [ "$D" -le 2 ]; then pass "header.stamp $STAMP_SEC vs now $NOW_SEC (diff ${D}s)"; else fail "header.stamp $STAMP_SEC vs now $NOW_SEC (diff ${D}s)"; fi
  else
    warn "could not read $TOPIC header.stamp"
  fi
  if has 'stop camera|stopped|QCarCamStop|disconnect camera server'; then pass "camera stopped on SIGINT"; else warn "no stop message seen"; fi

  run_node restart "$RUN_SECONDS" "" camera_id:="$CAMERA_ID"
  expect_frames "second start (after a clean stop)"
fi

# ---------------------------------------------------------------------------------------
# Step 6: selection rules and failure paths
# ---------------------------------------------------------------------------------------
if want_step 6; then
  CURRENT_STEP=6
  title "6. node: selection rules and failure paths"
  ros_env
  # The first fps line comes 5 s after the first frame: leave room for the start-up.
  SHORT=$(( RUN_SECONDS < 20 ? RUN_SECONDS : 20 ))
  EMPTY_CFG="$(mktemp -d /tmp/pd_empty_XXXXXX)"
  CUST_CFG="$(mktemp -d /tmp/pd_cust_XXXXXX)"
  printf 'origin: customer\ndomains:\n  camera:\n    backends: [ghost]\n' >"$CUST_CFG/50-camera-test.config.yaml"

  run_node 6.1_manual_param "$SHORT" "" camera_id:="$CAMERA_ID" camera_backend:="$BACKEND"
  if has "camera backends \(manual\): $BACKEND"; then pass "6.1 manual (parameter): only $BACKEND loaded"; else fail "6.1 '(manual)' missing"; fi
  expect_frames "6.1 manual (parameter)"

  run_node 6.2_manual_env "$SHORT" "PLUGIN_DISCOVERY_BACKEND_CAMERA=$BACKEND" camera_id:="$CAMERA_ID"
  if has "camera backends \(manual\): $BACKEND"; then pass "6.2 manual (environment): only $BACKEND loaded"; else fail "6.2 '(manual)' missing"; fi
  expect_frames "6.2 manual (environment)"

  run_node 6.3_other_board "$SHORT" "" camera_id:="$CAMERA_ID" camera_backend:="$OTHER_BACKEND"
  expect_refused "6.3 backend of the other board" "camera backend '$OTHER_BACKEND' is not available \(missing"

  if [ "$BOARD" = iq10 ]; then
    run_node 6.4_unknown_id "$SHORT" "" camera_id:=99
    expect_refused "6.4 unknown camera id" "does not report camera 99"
  else
    info "6.4 skipped on iq9: qmmf declares unlisted_ids (any camera id is accepted)"
  fi

  run_node 6.5_no_config "$SHORT" "PLUGIN_DISCOVERY_CONFIG_PATH=$EMPTY_CFG" camera_id:="$CAMERA_ID"
  if has "no configuration for domain 'camera'" && has 'camera backends \(all\)'; then pass "6.5 no configuration: all compatible backends loaded"
  else fail "6.5 expected the 'no configuration' warning and '(all)'"; fi
  expect_frames "6.5 no configuration"

  run_node 6.6_customer_ghost "$SHORT" "PLUGIN_DISCOVERY_CONFIG_PATH=/etc/plugin_discovery/platform.d:$CUST_CFG" camera_id:="$CAMERA_ID"
  expect_refused "6.6 customer default not installed (no fallback)" "default camera backend 'ghost' is not available \(missing"

  run_node 6.7_customer_plus_manual "$SHORT" "PLUGIN_DISCOVERY_CONFIG_PATH=/etc/plugin_discovery/platform.d:$CUST_CFG" camera_id:="$CAMERA_ID" camera_backend:="$BACKEND"
  expect_frames "6.7 customer config + manual backend"

  rm -r "$EMPTY_CFG" "$CUST_CFG"
fi

finish 0
