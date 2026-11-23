# 真机验证步骤（P5）

> **快速方式**：第 0～6 节已经写成脚本 [`tools/verify_board.sh`](tools/verify_board.sh)，在板子上的工作目录里运行：
> `bash qrb_ros_camera_pd/tools/verify_board.sh --board iq9`（IQ10：`--board iq10 --camera-id <inputId>`）。
> 脚本会逐项给出 PASS/FAIL，日志打包到 `verify_logs/<板子>-<时间>.tar.gz`。会改动系统的两步（`dpkg -i`、安装平台配置）执行前会先确认。下面是脚本做的事情的手动版本，排查问题时对照用。

在 IQ9 和 IQ10 上各做一遍。每一步都写了**预期结果**；结果不符时，先停下来，把这一步的输出保存好再继续（第 8 节列出要收集的内容）。

| | IQ9 | IQ10 |
|---|---|---|
| 要编译的 backend | `camera_backend_qmmf` | `camera_backend_qcarcam` |
| 跳过的 backend | `camera_backend_qcarcam` | `camera_backend_qmmf` |
| machine（`/sys/devices/soc0/machine`） | `QCS9075`（待确认） | `QAM8797P`（已确认） |
| `camera_id` | `0` | QCarCam 报出的某个 inputId（第 5 节日志里看，例如 5、6、11） |

## 原则：验证期间不改动板子的系统状态

上一次验证时，`apt install` 结束后 Ubuntu 的 `needrestart` 自动重启了一批平台服务（`qcx_server`、`pil-rm`、`glink` 等）。其中 `qcx_server.service` 的启动前置命令 `restorecon` 在这个镜像上不存在，所以 QCX 停掉之后就再也起不来了，相机随之不可用。所以这一版的步骤：

1. **不用 `apt install` 装本地 deb**，改用 `sudo dpkg -i`。dpkg 不会触发 needrestart，也不会顺带升级别的系统包。
2. 平台配置**默认不打 deb**，直接安装文件，再手动运行 `platform-detect`（第 4 节），不需要 debhelper。
3. 确实要用 apt 装东西时（比如 colcon），**先加 `-s` 模拟一遍**，确认没有 `Remv`（删除）和意外的 `Inst ... [旧版本]`（升级），再加上 `NEEDRESTART_MODE=l` 真正安装。
4. 开始之前先记录**基线**（第 0.4 节）；每装完一样东西，都和基线比一次。多出来的 failed 服务，就是我们这一步造成的。

---

## 0. 准备

### 0.1 拷代码到板子上

把 `plugin_discovery/` 和 `qrb_ros_camera_pd/` 拷到板子上的同一个工作目录（下文记为 `~/ws`）。**不要拷主机上的 `build/`、`install/`**：

```bash
# 在主机上
rsync -a --exclude build --exclude install --exclude log \
  plugin_discovery qrb_ros_camera_pd <user>@<板子IP>:~/ws/
```

### 0.2 检查依赖（只读）

```bash
cat /etc/os-release | head -3                 # 预期：Ubuntu 24.04
ls /opt/ros/jazzy/setup.bash                  # 预期：存在
which colcon                                  # 预期：存在（没有的话见下面）
which g++ make                                # 预期：都存在。新刷的镜像里可能没有：装 build-essential（方法同 colcon）
dpkg -l | grep -E 'libyaml-cpp-dev|^ii  cmake ' # 预期：libyaml-cpp-dev 0.8.x、cmake
dpkg -l | grep qrb-ros-transport-image-type   # 预期：ros-jazzy-qrb-ros-transport-image-type 已安装
grep -o 'yaml-cpp::yaml-cpp' /usr/lib/aarch64-linux-gnu/cmake/yaml-cpp/yaml-cpp-targets.cmake | head -1
                                              # 预期：输出 yaml-cpp::yaml-cpp
```

vendor SDK（编译 backend 需要**头文件和库都在**；不要求一定是某个 -dev 包提供的）：

```bash
# IQ9
ls /usr/include/qmmf-sdk/qmmf_recorder.h
ls /usr/lib/aarch64-linux-gnu/lib{camera_metadata,qmmf_recorder_client,qmmf_camera_metadata,qmmf_utils}.so
# IQ10
find /usr/include -name qcarcam.h
ls /usr/lib/aarch64-linux-gnu/lib{qcxclient,qcxosal}.so
```

缺 colcon 时（先模拟，确认没有删除和意外升级，再安装）：

```bash
sudo apt-get -s install python3-colcon-common-extensions | grep -E '^(Inst|Remv)'
sudo NEEDRESTART_MODE=l apt install python3-colcon-common-extensions
```

### 0.3 记录板子信息（C1）

```bash
cat /sys/devices/soc0/machine
```

预期：IQ9 为 `QCS9075`，IQ10 为 `QAM8797P`。不一样时，把 `qrb_ros_camera_pd/qrb_camera_platform_config/config/` 下对应文件的文件名改成实际值（只改开头的 machine 部分），**并同步改 `qrb_camera_platform_config/CMakeLists.txt` 里的文件名**，再继续。

### 0.4 记录基线

```bash
systemctl --failed --no-pager --plain | tee ~/ws/baseline_failed.txt
systemctl is-active qcx_server.service pil-rm.service   # IQ10
ps -ef | grep -c [q]cxserver                            # IQ10：预期 1
```

**IQ10 上 `qcx_server` 必须是 `active`、能看到 `qcxserver` 进程**，否则相机本身就不可用，先不要往下做，把输出发给我。

之后每一步结束时都可以用下面这条命令和基线比较，**预期没有任何输出**：

```bash
diff <(sort ~/ws/baseline_failed.txt) <(systemctl --failed --no-pager --plain | sort)
```

---

## 1. 安装 plugin_discovery

```bash
cd ~/ws/plugin_discovery
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DPLUGIN_LOADER_BUILD_TESTS=ON
cmake --build build -j$(nproc)
build/test/registry_test build/test/backends 2>/dev/null | tail -1   # 预期：all passed
# 日志在 stderr，上面丢掉了；里面的 ERROR/WARN 是测试故意制造的失败场景。想看就去掉 2>/dev/null
(cd build && cpack -G DEB)
sudo dpkg -i build/plugin-discovery_*.deb
```

如果 `dpkg -i` 报依赖不满足，**停下来**，不要执行 `apt -f install`，把输出发给我。

检查：

```bash
which platform-detect pluginlib-detect               # 预期：/usr/bin/platform-detect、/usr/bin/pluginlib-detect
systemctl is-enabled plugin-discovery-platform-detect.service   # 预期：enabled
cat /var/lib/plugin_discovery/platform-detect.done   # 预期：machine=<0.3 的值>  os=ubuntu  links=0
diff <(sort ~/ws/baseline_failed.txt) <(systemctl --failed --no-pager --plain | sort)   # 预期：无输出
```

此时还没有候选文件，`links=0` 是正常的。

---

## 2. 编译本仓库

两块板用同一条命令，**不指定任何 backend**：

```bash
cd ~/ws
source /opt/ros/jazzy/setup.bash
colcon build --base-paths qrb_ros_camera_pd --cmake-args -DBUILD_TESTING=ON -DREQUIRE_ALL_BACKENDS=OFF
```

每个 backend 是一个独立的包，找得到自己的 vendor SDK 就编译，找不到就跳过自己，只打一条 CMake 警告（`camera backend 'qcarcam' skipped: QCarCam SDK not found ...`），不会让整次编译失败。所以 IQ9 上会编出 qmmf、跳过 qcarcam，IQ10 上正好相反。`REQUIRE_ALL_BACKENDS` 本来默认就是 OFF，这里写出来只是为了覆盖以前用 ON 编译时留在 CMake 缓存里的值。`Manually-specified variables were not used` 这类警告可以忽略。

**预期**：所有包编译成功（`Summary: N packages finished`），而且**本板的 backend 确实编出来了**（看下面的 `find`）。如果本板的 backend 也被跳过了，说明本板的 SDK 没找到，看这个包的编译日志 `log/latest_build/<包名>/stdout_stderr.log`。**编译失败时，把完整输出发给我。** IQ9 的 qmmf backend 还没有在真机上编译过。

```bash
source install/setup.bash
find install -name '*.plugin.yaml'
# 预期（IQ9）：install/camera_backend_qmmf/share/camera/plugins/camera_backend_qmmf.plugin.yaml
# 预期（IQ10）：install/camera_backend_qcarcam/share/camera/plugins/camera_backend_qcarcam.plugin.yaml
```

---

## 3. 管理层单元测试（在板子上再跑一遍）

```bash
./build/qrb_camera/test/camera_manager_test 2>/dev/null | tail -1
```

**预期**：`all passed (95/95 checks)`。

---

## 4. 安装平台配置

### 4.1 默认方式：直接安装文件（不经过 apt/dpkg）

```bash
cd ~/ws
sudo cmake --install build/qrb_camera_platform_config --prefix /usr
sudo platform-detect --force
```

检查：

```bash
ls /usr/share/plugin_discovery/platforms.d/
# 预期：QAM8797P-Ubuntu-camera.config.yaml  QCS9075-Ubuntu-camera.config.yaml
ls -l /etc/plugin_discovery/platform.d/
# 预期（IQ9）：camera.config.yaml -> /usr/share/plugin_discovery/platforms.d/QCS9075-Ubuntu-camera.config.yaml
# 预期（IQ10）：camera.config.yaml -> /usr/share/plugin_discovery/platforms.d/QAM8797P-Ubuntu-camera.config.yaml
cat /var/lib/plugin_discovery/platform-detect.done   # 预期：links=1
```

### 4.2 可选：验证 deb 的 postinst（需要 debhelper）

只在需要验证打包时才做。debhelper 要通过 apt 安装，按“原则”第 3 条先模拟：

```bash
sudo apt-get -s install debhelper | grep -E '^(Inst|Remv)'      # 确认没有 Remv 和意外升级
sudo NEEDRESTART_MODE=l apt install debhelper
cd ~/ws/qrb_ros_camera_pd/qrb_camera_platform_config
dpkg-buildpackage -us -uc -b
sudo dpkg -i ../ros-jazzy-qrb-camera-platform-config_0.1.0_all.deb   # postinst 会运行 platform-detect --force
cd ~/ws
```

检查同 4.1。

### 4.3 查看合并结果

```bash
export PLUGIN_DISCOVERY_PATH=$(ls -d $PWD/install/*/share/camera/plugins | paste -sd:)
pluginlib-detect -d camera
unset PLUGIN_DISCOVERY_PATH      # 之后让 CameraManager 自己找清单，验证这条路径也通
diff <(sort ~/ws/baseline_failed.txt) <(systemctl --failed --no-pager --plain | sort)   # 预期：无输出
```

**预期**（IQ10 为例，IQ9 把 qcarcam 换成 qmmf）：

```
Domain camera
  load order (first = default):
    1. qcarcam  [platform] /etc/plugin_discovery/platform.d/camera.config.yaml
```

这一项后面**不应该**出现 `(not installed)`。

---

## 5. 运行节点：正常路径

先确认 QCX 还在（IQ10）：`systemctl is-active qcx_server.service`，预期为 `active`。

```bash
source /opt/ros/jazzy/setup.bash && source ~/ws/install/setup.bash
# IQ9
ros2 launch qrb_ros_camera qrb_ros_camera_launch.py camera_id:=0 enable_test_node:=true
# IQ10（camera_id 用实际接了 sensor 的 inputId）
ros2 launch qrb_ros_camera qrb_ros_camera_launch.py camera_id:=5 enable_test_node:=true
```

`camera_info_path` 默认用包里的示例标定文件，只影响 `camera_info` 话题里的内参，不影响出帧，不用指定。

**预期日志**（按顺序）：

| 日志 | 说明 |
|---|---|
| `[CameraManager]: camera backends (config): qmmf [0]; default: qmmf`（IQ10：`qcarcam [<inputId 列表>]; default: qcarcam`） | 清单找到、配置生效、probe 成功。IQ10 方括号里是 QCarCam 报出的 inputId，**请记下来** |
| `[CameraManager]: created camera <id> on backend '<backend>'` | |
| `camera <id> on backend '<backend>'` | 节点侧 |
| `camera clock: ... ros time: ... time offset: ... ns` | 时间偏移已计算 |
| `[CameraManager]: started camera <id> on backend '<backend>'` | |
| `QRB Camera Node init success` | |
| 每 5 秒一条 `name: stream1, fmt nv12, w x h[1280 x 720] ... Fps: ~30, ... latency <N> us` | **收到帧**，通过标准 |

常见失败及含义：

| 日志 | 含义 |
|---|---|
| `skipped qcarcam [missing]: configured but not installed` | 没找到清单：检查第 2 节的 `find` 结果和是否 `source install/setup.bash` |
| `skipped camera/QCarCamCamera [fault]: QCarCamInitialize failed ... QCX server is not running` | QCX 没在运行（`systemctl is-active qcx_server`），不是本仓库的问题 |
| `does not report camera <id> (it reports: ...)` | `camera_id` 不在 QCarCam 报出的列表里，换成列表里的值 |

**通过标准**：
1. 持续打出 fps 日志，`Fps` 接近 30。
2. `latency` 是正数，在几毫秒到几十毫秒之间。负数或秒级说明时间偏移不对（时钟域错了）。
3. 另开一个终端，查时间戳和当前时间是否接近：
   ```bash
   ros2 topic echo --once /cam<id>_stream1_camera_info --field header.stamp; date +%s
   ```
   预期：`sec` 和 `date +%s` 相差 1 秒以内。

然后 `Ctrl-C` 退出。**预期**：能看到 stop camera 相关日志，进程正常退出，没有 `Segmentation fault` 或 `core dumped`。

**再启动一次**同样的命令（验证 stop 之后能重新启动），预期和第一次一样。

> IQ10 上，这一步能出帧就说明“SDK 初始化由 backend 持有”的方案在真机上可行（DESIGN 5.3）。

---

## 6. 运行节点：选择规则和失败路径

下面每个用例都只看启动阶段：需要出帧的，看到 fps 日志后 `Ctrl-C`；预期失败的，看节点加载失败的报错。命令里省略的参数同第 5 节（`camera_id`）。

| # | 用例 | 命令差异 | 预期 |
|---|---|---|---|
| 6.1 | 人工指定本板的 backend | `camera_backend:=qmmf`（IQ10：`qcarcam`） | `camera backends (manual): ...`，出帧 |
| 6.2 | 环境变量人工指定 | 命令前加 `PLUGIN_DISCOVERY_BACKEND_CAMERA=qmmf`（IQ10：`qcarcam`） | 同 6.1 |
| 6.3 | 指定另一块板的 backend（负面用例） | IQ9：`camera_backend:=qcarcam`；IQ10：`camera_backend:=qmmf` | 节点加载失败，报 `camera backend '...' is not available (missing: configured but not installed)`；**不崩溃** |
| 6.4 | 不存在的 camera id（IQ10） | `camera_id:=99` | 节点加载失败，报 `backend 'qcarcam' does not report camera 99 (it reports: ...)` |
| 6.5 | 没有配置 | 命令前加 `PLUGIN_DISCOVERY_CONFIG_PATH=/tmp/pd_empty`（先 `mkdir -p /tmp/pd_empty`） | WARN `no configuration for domain 'camera' ...`，然后 `camera backends (all): ...`；本板只装了一个 backend，所以仍然出帧 |
| 6.6 | 客户配置：默认项改成没安装的 backend | 见下面的命令 | 节点加载失败，报 `the default camera backend 'ghost' is not available (missing: ...)`，**不会回退**到本板的 backend |
| 6.7 | 客户配置加人工指定 | 在 6.6 的基础上再加 `camera_backend:=qmmf`（IQ10：`qcarcam`） | 人工指定覆盖配置，出帧 |

6.6 的客户配置：

```bash
mkdir -p /tmp/pd_cust
printf 'origin: customer\ndomains:\n  camera:\n    backends: [ghost]\n' > /tmp/pd_cust/50-camera-test.config.yaml
PLUGIN_DISCOVERY_CONFIG_PATH=/etc/plugin_discovery/platform.d:/tmp/pd_cust \
  ros2 launch qrb_ros_camera qrb_ros_camera_launch.py camera_id:=<id>
```

用 `pluginlib-detect` 也能看到同样的结果（按 4.3 设置 `PLUGIN_DISCOVERY_PATH`，再加 `--config-path /etc/plugin_discovery/platform.d:/tmp/pd_cust`）：`ghost` 排在第一位。

---

## 7. 可选：冷启动（C4，只看现象，不要求通过）

IQ10 上重启板子，系统起来后**立刻**运行第 5 节的命令，记录：
- 节点能否启动；
- 不能启动时，`camera backends` 那一行和 `skipped camera/QCarCamCamera [fault]: ...` 的原因；
- 等待多久之后再启动就正常了（同时看 `systemctl is-active qcx_server.service`）。

这些信息用来设计后续的 QCX 就绪处理。

---

## 8. 要发给我的内容

1. 第 0.3 节 IQ9 的 `/sys/devices/soc0/machine`（IQ10 已确认为 `QAM8797P`）。
2. 第 0.4 节的基线，以及之后任何一次 `diff` 有输出的情况。
3. 第 2 节编译失败时的完整输出（成功就不用发）。
4. 第 5 节的完整启动日志，从 `QRB Camera Node start` 到第一条 fps 日志；以及 `Ctrl-C` 退出时的日志。
5. 第 6 节每个用例的结果：通过/不通过；不通过时附日志。
6. IQ10 第 5 节日志里 `qcarcam [...]` 报出的 inputId 列表。
7. （可选）第 7 节的观察。

## 9. 清理（验证完之后）

```bash
# 4.1 方式安装的平台配置
sudo rm /usr/share/plugin_discovery/platforms.d/QCS9075-Ubuntu-camera.config.yaml \
        /usr/share/plugin_discovery/platforms.d/QAM8797P-Ubuntu-camera.config.yaml
sudo platform-detect --force            # 删掉指向它们的链接
# 4.2 方式安装的：sudo dpkg -r ros-jazzy-qrb-camera-platform-config
sudo dpkg -r plugin-discovery
rm -r /tmp/pd_empty /tmp/pd_cust
```
