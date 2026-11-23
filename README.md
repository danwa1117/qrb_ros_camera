# qrb_ros_camera_pd

基于 [plugin_discovery](https://github.com/qualcomm-qrb-ros/plugin_discovery) 的跨平台 `qrb_ros_camera`：同一套代码、同一个 Ubuntu 镜像，IQ9 上使用 QMMF/CamX，IQ10 上使用 QCarCam。加载哪个 backend 由配置决定，代码里不做 SoC 判断。

> 状态：设计已确认，代码实现中，**尚未在真机验证**。设计细节见 [DESIGN.md](DESIGN.md)，真机验证步骤见 [VERIFY.md](VERIFY.md)。

## 包

| 包 | 作用 | 依赖 ROS |
|---|---|---|
| `camera_interface` | camera 域接口：`ICameraBackend`、`ICameraDevice`、frame/listener 类型 | 否 |
| `camera_backend_qmmf` | IQ9 backend，封装 QMMF/CamX | 否 |
| `camera_backend_qcarcam` | IQ10 backend，封装 QCarCam | 否 |
| `qrb_camera` | `CameraManager`：通过 plugin_discovery 加载 backend，创建和管理相机 | 否 |
| `qrb_ros_camera` | ROS 2 组件节点 | 是 |
| `qrb_camera_platform_config` | IQ9 和 IQ10 的平台配置候选文件 | 否 |

| 平台 | machine（暂定） | 默认 backend |
|---|---|---|
| IQ9 + Ubuntu | `QCS9075` | `qmmf` |
| IQ10 + Ubuntu | `QAM8797P` | `qcarcam` |

## 依赖

- [plugin_discovery](https://github.com/qualcomm-qrb-ros/plugin_discovery) ≥ 0.3.0（deb：`plugin-discovery`，装在 `/usr`）。构建和运行都需要它。
- `yaml-cpp`（plugin_discovery 依赖）、C++17、CMake ≥ 3.16。
- vendor SDK：IQ9 是 QMMF SDK；IQ10 是 `camera-qcx-dev`（`qcarcam.h`、`libqcxclient`、`libqcxosal`）。找不到某个 SDK 时，对应的 backend 会被跳过、不编译。
- ROS 2 Jazzy（只有 `qrb_ros_camera` 需要）。

## 构建

```bash
# 1. plugin_discovery（只需一次）
cd plugin_discovery
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
cmake --build build -j
(cd build && cpack -G DEB) && sudo apt install ./build/plugin-discovery_*.deb

# 2. 本仓库
source /opt/ros/jazzy/setup.bash
colcon build --base-paths qrb_ros_camera_pd
```

`-DREQUIRE_ALL_BACKENDS=ON`：缺少 vendor SDK 时报错，而不是跳过对应的 backend。

### 在 x86 上测试管理层（不需要 vendor SDK 和 ROS）

```bash
PD=<plugin_discovery 的 install 目录>; INST=$PWD/install
cmake -S camera_interface -B build/camera_interface -DCMAKE_INSTALL_PREFIX=$INST -DCMAKE_PREFIX_PATH=$PD
cmake --install build/camera_interface
cmake -S qrb_camera -B build/qrb_camera -DCMAKE_INSTALL_PREFIX=$INST -DCMAKE_PREFIX_PATH="$PD;$INST"
cmake --build build/qrb_camera -j && (cd build/qrb_camera && ctest --output-on-failure)
```

`camera_manager_test` 用 fake backend 测试选择规则、人工指定、默认项不可用时报错、camera id 校验、生命周期和析构顺序。

Ubuntu 22.04 自带 yaml-cpp 0.7，它没有 plugin_discovery 需要的 `yaml-cpp::yaml-cpp` target（0.8 才有；Ubuntu 24.04 自带 0.8，没有这个问题）。在 22.04 上构建 plugin_discovery 时加一个 alias：

```bash
cat > /tmp/yaml_cpp_alias.cmake <<'EOF'
find_package(yaml-cpp REQUIRED)
if(TARGET yaml-cpp AND NOT TARGET yaml-cpp::yaml-cpp)
  add_library(yaml-cpp::yaml-cpp ALIAS yaml-cpp)
endif()
EOF
cmake -S plugin_discovery -B build ... -DCMAKE_PROJECT_plugin_discovery_INCLUDE=/tmp/yaml_cpp_alias.cmake
```

如果装了 anaconda 之类自带 yaml-cpp 的环境，还要加 `-Dyaml-cpp_DIR=/usr/lib/x86_64-linux-gnu/cmake/yaml-cpp`，否则可能链接到它的版本。

## 部署

```bash
sudo apt install ./ros-jazzy-*.deb      # 接口、backend、qrb_camera、节点、平台配置
# 平台配置包的 postinst 会运行 platform-detect --force，按本机 machine 链接配置
pluginlib-detect -d camera --path /opt/ros/jazzy/share/camera/plugins
```

在 IQ10 上，正确的输出应该是：

```
Domain camera
  load order (first = default):
    1. qcarcam  [platform] /etc/plugin_discovery/platform.d/camera.config.yaml
```

如果 `pluginlib-detect` 提示没有配置，先核对 machine：

```bash
cat /sys/devices/soc0/machine
cat /var/lib/plugin_discovery/platform-detect.done
platform-detect --dry-run
```

候选文件名中的 machine 必须和板子上读到的值完全一致（只忽略大小写）。没有匹配时，camera 域保持未配置，所有 backend 都会加载，默认项按插件名排序是 qcarcam，**IQ9 上会因此无法启动**。

## 运行

```bash
# 默认 backend 由平台配置决定
ros2 launch qrb_ros_camera qrb_ros_camera_launch.py camera_id:=0

# 指定 backend（只加载这一个，绕过配置）
ros2 launch qrb_ros_camera qrb_ros_camera_launch.py camera_backend:=qcarcam camera_id:=11 ...
PLUGIN_DISCOVERY_BACKEND_CAMERA=qcarcam ros2 launch ...     # 等价写法
```

- `camera_id` 是 backend 自己的 id：IQ9 是 QMMF 的 camera id，IQ10 是 QCarCam 的 inputId（例如 11、6）。
- `camera_info_path` 默认用包里自带的示例标定 `camera_info_OX03F10_yuv.yaml`（同 IQ10 原来的 launch）。它只影响 `camera_info` 话题里的内参，不影响出帧；需要准确内参时，再指定实际传感器的标定文件。

## 客户配置

把 `NN-camera-<来源>.config.yaml` 放进 `/etc/plugin_discovery/config.d/`。例如，把自己的 backend 放到最前面：

```yaml
domains:
  camera:
    backends: [my_camera]
```

规则（`backends`、`disable`、`reset`）见 plugin_discovery 的 `docs/TEMPLATES.md`。

## 已知问题

### IQ10：节点比 QCX 先启动时启动失败

只有把节点做成开机自启动时才会遇到。`qcx_server` 本身开机自启动，节点在开机之后手动启动时，QCX 已经就绪，不会有这个问题。

**现象**：节点在 QCX server 就绪之前启动（例如由 systemd 或开机脚本在开机过程中拉起），节点启动失败，日志类似：

```
skipped camera/QCarCamCamera [fault]: QCarCamInitialize failed ...
create_camera failed: default backend 'camera/QCarCamCamera' is not loaded (fault)
```

**原因**：QCX server 是一个独立进程，开机时它不一定先于节点就绪。qcarcam backend 在加载时（`probe()`）会初始化 QCarCam；此时 QCX 还没就绪，就会报 Fault，节点没有可用的 backend。目前没有可靠的就绪检测手段（原代码里检查 `/dev/mqueue/QCX_debfcadf` 的逻辑并不可靠，已注释掉），所以暂时没有在 probe 里等待或重试。

**规避方法**：
- 手动启动：确认 `systemctl is-active qcx_server.service` 为 `active` 后再执行 `ros2 launch ...`。
- 开机自启动：节点的 systemd unit 里加上
  ```ini
  [Unit]
  Wants=qcx_server.service
  After=qcx_server.service
  ```
  `qcx_server.service` 的类型是 `Type=notify`，`After=` 会等到它报告就绪之后才启动节点。

如果以后需要节点开机自启动，还可以在 qcarcam 的 `probe()` 里加有限次的重试（DESIGN.md 第 11 节，C4）。

### 帧数据在回调返回后不再有效（IQ9 和 IQ10 都是）

`CameraFrame::data` 和 `fd`、以及节点发布出去的图像消息里的 dma-buf，指向的都是 backend 的 buffer。回调一返回，这个 buffer 就会还给驱动（QCarCam）或 recorder（QMMF），几帧之后就会被新数据覆盖。订阅方处理得慢，或者消息在队列里排队时，可能读到后面的帧。要在回调之外使用数据，必须在回调内拷贝，或者 `dup()` fd 并尽快处理完。这是原来 IQ9 和 IQ10 实现就有的行为（DESIGN.md 第 11 节 R7）。

## 许可证

BSD-3-Clause-Clear
