# qrb_ros_camera_pd 详细设计

状态：设计已确认（2026-11-20），代码尚未实现，**尚未在真机验证**。

本仓库基于 [plugin_discovery](https://github.com/qualcomm-qrb-ros/plugin_discovery)（≥ 0.3.0），让同一套 `qrb_ros_camera` 在同一个 Ubuntu 镜像里，IQ9 上使用 QMMF/CamX，IQ10 上使用 QCarCam。代码中不做 SoC 判断。

相关文档：[README.md](README.md)（构建、部署、运行、已知问题）、plugin_discovery 的 `docs/CROSS_PLATFORM_DESIGN.md`（顶层设计、原则 D1–D9）、`docs/LIBRARY.md`（API 与配置规则）。

---

## 1. 目标与范围

| 目标 | 落点 |
|---|---|
| 一套代码、一个 Ubuntu 镜像覆盖 IQ9 和 IQ10 | 每个 vendor SDK 一个 backend，由配置决定加载哪个 |
| 代码里没有 SoC 判断 | machine 只在 `platform-detect` 选平台配置时用到（第 8 节），库和 pd 都不读 |
| ROS 只是 consumer 之一 | 除 `qrb_ros_camera` 外都是不依赖 ROS 的纯 CMake 包 |
| 客户可扩展 | 客户写自己的 backend 加一个客户配置文件，不用改 pd |

**不在本次范围内**：`compat` 回退（plugin_discovery 目前只解析、不生效）、把 QCarCam 改成真正的 refcount、snapshot 补全、V4L2 backend、QLI（QCLinux）。

## 2. 已确认的决策

| # | 决策 |
|---|---|
| A1 | 新建 `qrb_ros_camera_pd/`，`qrb_ros_camera_cross` 只作参考 |
| A2 | 除 `qrb_ros_camera` 外都是纯 CMake 包，带 `package.xml`（`<build_type>cmake</build_type>`）以便 colcon 构建，不依赖 ROS |
| A3 | 时钟域由 backend 提供（`ICameraDevice::now_ns()`），节点不认识 backend 的名字 |
| A4 | 不使用 ROS pluginlib、`plugin.xml`、`*.backend.yaml`、自研的 registry/policy 和 `camera_backend_detect`，改由 plugin_discovery 和 `pluginlib-detect` 承担（见第 3.1 节） |
| A5 | 调用方不指定 backend 时，用配置合并后列表的第一项（`BackendSet::first`）；它不可用就报错，不回退 |
| A6 | 只做 Ubuntu |
| A7 | `camera_id` 使用各 backend 自己的 id：IQ9 是 QMMF 的 camera id，IQ10 是 QCarCam 的 inputId |
| A8 | deb 包名统一使用 `ros-jazzy-` 前缀 |
| A9 | 平台配置先在本仓库的 `qrb_camera_platform_config` 里维护，以后移交给平台 owner（第 8.3 节） |

## 3. 包结构与依赖

```
plugin_discovery（外部依赖，deb：plugin-discovery，装在 /usr）
   ▲
camera_interface ◀── camera_backend_qmmf     链接 QMMF SDK
   ▲            ◀── camera_backend_qcarcam  链接 qcxclient / qcxosal
qrb_camera（CameraManager）    只链接 camera_interface 和 plugin_discovery，不链接任何 backend
   ▲
qrb_ros_camera（ROS 2 组件节点）
qrb_camera_platform_config      只有 YAML，构建不依赖任何包
```

| 包 | 类型 | deb | 安装内容 |
|---|---|---|---|
| `camera_interface` | CMake，只有头文件 | `ros-jazzy-camera-interface` | `include/camera_interface/` |
| `camera_backend_qmmf` | CMake | `ros-jazzy-camera-backend-qmmf` | `lib/camera/libcamera_backend_qmmf.so`，`share/camera/plugins/camera_backend_qmmf.plugin.yaml` |
| `camera_backend_qcarcam` | CMake | `ros-jazzy-camera-backend-qcarcam` | `lib/camera/libcamera_backend_qcarcam.so`，`share/camera/plugins/camera_backend_qcarcam.plugin.yaml` |
| `qrb_camera` | CMake | `ros-jazzy-qrb-camera` | `lib/libqrb_camera.so`，头文件 |
| `qrb_ros_camera` | ament | `ros-jazzy-qrb-ros-camera` | 组件、launch、camera_info |
| `qrb_camera_platform_config` | CMake | `ros-jazzy-qrb-camera-platform-config` | `/usr/share/plugin_discovery/platforms.d/*-camera.config.yaml` |

`ros-jazzy-*` 包的 prefix 是 `/opt/ros/jazzy`（同 IQ10 现有的 `debian/rules`）。只有平台配置候选文件**例外，固定装到 `/usr/share/plugin_discovery/platforms.d/`**，因为 `platform-detect` 只看这个目录。

### 3.1 和 qrb_ros_camera_cross 的对应关系

| cross 版组件 | 现在由谁承担 |
|---|---|
| ROS pluginlib（`ClassLoader`、`PLUGINLIB_EXPORT_CLASS`） | plugin_loader，加上注册宏 `PLUGIN_DISCOVERY_REGISTER_BACKEND` |
| `plugin.xml`、`*.backend.yaml` | `plugin_discovery_add_plugin()` 生成的 `*.plugin.yaml` 清单 |
| `BackendRegistry`（扫描、校验、去重） | `PluginRegistry::scan()`，另外在加载时校验接口版本和 ABI |
| `BackendPolicy`（配置目录、合并、`QRB_CAMERA_BACKEND`） | plugin_discovery 的配置合并，以及 `PLUGIN_DISCOVERY_BACKEND_CAMERA` |
| `DuplicateDevice` 去重 | `load<T>()` 内置 |
| `camera_backend_detect` | `pluginlib-detect -d camera` |
| 两个 backend 的内部实现、fake backend 测试思路 | **保留并复用** |

## 4. 接口 `camera_interface`（camera 1.0）

```cpp
namespace qrb_camera {
// ICameraFrame / ICameraListener / CameraFrame / StreamParam / CameraParam /
// CameraConfigure：合并 IQ9 和 IQ10 的现有定义，字段保持不变。

class ICameraDevice {
public:
  explicit ICameraDevice(uint32_t id);
  virtual ~ICameraDevice();
  virtual bool init() = 0;
  virtual void set_param(std::vector<CameraParam> & param) = 0;
  virtual int  start_camera() = 0;
  virtual int  stop_camera() = 0;
  virtual void add_listener(ICameraListener * listener) = 0;
  virtual void remove_listener(ICameraListener * listener) = 0;
  // frame->timestamp 所在时钟域的当前时间（ns）。QMMF：CLOCK_BOOTTIME；QCarCam：QTimer。
  virtual int64_t now_ns() const = 0;
  bool working() const;
  uint32_t get_id() const;
};

class ICameraBackend : public plugin_discovery::Backend {
public:
  virtual std::string name() const = 0;   // "qmmf" / "qcarcam"，等于清单里的 backend:
  virtual std::unique_ptr<ICameraDevice> open(const plugin_discovery::DeviceInfo & device) = 0;
  // probe() 继承自 plugin_discovery::Backend
};
}  // namespace qrb_camera

PLUGIN_DISCOVERY_INTERFACE(qrb_camera::ICameraBackend, "camera", 1, 0)
```

- 头文件分两个：`camera_interface/camera_types.hpp` 放 `StreamType`、`CameraFrame`、`ImageCallback`、`StreamParam`、`CameraParam`、`CameraConfigure` 和内外参，即原 `qrb_camera_common.hpp` 加上 `ImageCallback`；`camera_interface/camera_interface.hpp` 放 `ICameraFrame`、`ICameraListener`、`ICameraDevice`、`ICameraBackend`。
- listener 不由 backend 提供。原来的 `QMMFListener` 和 `QCarCamListener` 逻辑完全一样，都是把 `ICameraFrame` 的字段拷进 `CameraFrame` 再调回调，所以 `qrb_camera` 用一个通用的 `FrameListener` 统一实现。好处是 listener 的代码不在 backend 的 `.so` 里，生命周期更简单。backend 包里删掉各自的 listener。
- 删掉 `CameraType` 枚举。`DeviceInfo.id` 是十进制字符串，`open()` 时转成 `uint32_t` 传给设备的构造函数。
- 版本规则：只在末尾追加虚函数时升 minor，其他改动升 major。backend 和 App 的 major 必须相同，且 backend 的 minor 不小于 App 的 minor。
- **buffer 语义**（写进接口注释）：QMMF 的 `acquire_ref()` 能延长 buffer 的生命期；QCarCam 在回调返回后就会回提 buffer，refcount 只是摆设。要跨出回调使用数据，必须在回调内拷贝或 dup fd。

## 5. backend

### 5.1 注册

| | qmmf | qcarcam |
|---|---|---|
| `NAME` | `camera/QMMFCamera` | `camera/QCarCamCamera` |
| `CLASS` | `qrb_camera::QMMFBackend` | `qrb_camera::QCarCamBackend` |
| `BACKEND` | `qmmf` | `qcarcam` |
| `ORIGIN` | `qcom` | `qcom` |
| vendor SDK 检测 | `qmmf-sdk/qmmf_recorder.h`，以及 `camera_metadata`、`qmmf_recorder_client`、`qmmf_camera_metadata`、`qmmf_utils` | `qcarcam.h`，以及 `qcxclient`、`qcxosal` |
| 代码来源 | IQ9 的 `qmmf_*` | IQ10 2.0.3（`dev/robot-iq10`）的 `qcarcam_*`，`getQtimerTime()` 从节点挪进来 |

找不到 SDK 时跳过这个 backend；`-DREQUIRE_ALL_BACKENDS=ON` 时改为报错。

**编译时、装镜像时、运行时各自决定什么**（任何一个阶段都不需要人工指定 backend）：

| 阶段 | 决定什么 | 由谁决定 |
|---|---|---|
| 编译 | 编出哪些 backend | 哪些 vendor SDK 在场：每个 backend 包找不到自己的 SDK 就自动跳过。`REQUIRE_ALL_BACKENDS=ON` 只用在“这个包必须编出来”的场合，例如某个 backend 自己的 recipe 或 deb 构建：它已经依赖了 SDK，还找不到就应该报错 |
| 装镜像 | 板子上装哪些 backend | LU：统一镜像把所有 backend 的 deb 都装上。LE：每个 machine 的镜像里放对应 backend 的 recipe（`IMAGE_INSTALL`），就像放驱动一样 |
| 运行 | 用哪个 backend | 平台配置（第一项为默认）加上 `probe()`。`camera_backend` 参数和 `PLUGIN_DISCOVERY_BACKEND_CAMERA` 只用于调试时手动覆盖 |

`qrb_camera` 和 `qrb_ros_camera` 不依赖、也不知道任何 backend，所以它们的构建既没有 backend 参数，也不需要 backend 参数。

### 5.2 `probe()`

约定：每个进程里 probe 只调用一次；不打开、不启动相机；返回 Unsupported 或 Fault 时不崩溃、不留下任何残留（不留打开的设备、线程或 SDK 会话）。返回 Ok 时 backend 会一直保持加载，允许持有进程级的 SDK 状态（plugin_discovery 的契约只对 Unsupported/Fault 要求干净退出）。

| | qmmf | qcarcam |
|---|---|---|
| Unsupported | `Connect` 失败（没有 QMMF 服务） | —（只有被配置列出才会加载，失败时按 Fault 处理） |
| Fault | 能连上，但枚举相机失败 | `QCarCamInitialize` 失败，或 `QCarCamQueryInputs` 为空（先 Uninitialize 再返回） |
| Ok + 设备 | 报 `"0"`，清单里声明 capability `unlisted_ids`。**已决定（2026-11-23）：沿用原来 IQ9 的做法，不做相机枚举**：`camera_id` 由调用方给出，打开时由 QMMF 校验 | 每个 inputId 一项，`node` 为空；**保持已初始化状态** |
| probe 结束后的 SDK 状态 | 临时 `Connect` 后马上 `Disconnect`；每个设备的 Recorder 自己 Connect | 已初始化，由 backend 持有 |
| 等待与重试 | 无 | **暂时不做**，见第 11 节的 `TODO(C4)` |

### 5.3 QCarCam 的 SDK 初始化由 backend 持有

整个进程只调用一次 `QCarCamInitialize`，由 `QCarCamBackend` 持有：

```
QCarCamBackend::probe()   QCarCamInitialize → QCarCamQueryInputs → 成功则保持已初始化
QCarCamBackend::open(id)  new QCarCamCamera(id)：设备不调 Initialize/Uninitialize，
                          只做 Open / SetParam / SetBuffers / Reserve / Start / Stop / Release / Close
~QCarCamBackend()         如果已初始化，调 QCarCamUninitialize
```

- 和 IQ10 现有代码的区别：`QCarCamInitialize` 从 `QCarCamCamera::init()` 挪到 `probe()`，`QCarCamUninitialize` 从 `stop_camera()` 挪到 backend 的析构函数。Open、Reserve、buffer、回提这些逻辑不变。
- 理由：不依赖“初始化、释放、再初始化”这个没验证过的 SDK 行为；同一进程里开多路相机（例如一个 `component_container` 里放多个节点）时也只初始化一次；SDK 会话是进程级状态，交给生命周期由 plugin_discovery 管理的 backend 对象最合适。
- 析构顺序由第 6 节保证：所有设备先于 backend 销毁，backend 先于它的 `.so` 卸载，所以 Uninitialize 时不会还有设备在使用会话。
- 代价：节点存活期间一直保持 QCX 连接。QCX server 中途重启的情况记在第 11 节 R3。

### 5.4 移植时对原有代码的修改

vendor 调用顺序、buffer 分配和回提机制都保持不变。下面这些是原代码里会导致未定义行为或资源泄漏的问题，移植时一并修了，源码里以 `Fix:` 标注：

| backend | 原有问题 | 修改 |
|---|---|---|
| qmmf | `QMMFFrame::release_ref()` 在持有自身互斥锁时调用回调删除自己，然后又对已释放的 `refs_` 自减 | 先在锁内算出剩余计数，释放锁之后再删除 |
| qmmf | 没有 listener 时，`track_data_cb` 和 `snapshot_cb` 先 new 了 frame，归还 buffer 后直接返回，frame 泄漏 | 先检查，再分配 frame；buffer 为空时同样直接归还 |
| qmmf | `stop_camera()` 在遍历 `snap_streams_` 的同时 erase 元素（迭代器失效）；track 循环里的 erase 是写在 return 后面的死代码 | 遍历完再统一清空；单步出错时继续拆除后续资源，最后返回 -1 |
| qmmf | 重复 `init()`（每次 `start_camera` 前都会调）会把 stream 追加进容器，第二次启动时同一 track 会出现两次 | `init()` 先清空 stream 再重建；已连接就不重复 `Connect` |
| qmmf | 遇到不认识的格式字符串时，`VideoFormat` 未初始化就被使用 | 打 WARNING，按 nv12 处理 |
| qmmf | `init()` 或 `start_camera()` 中途失败后，Recorder 一直保持连接或相机保持启动 | 析构时按状态调 `StopCamera` 和 `Disconnect` |
| qcarcam | — | 只做第 5.3 节的初始化改动，删掉被注释掉的 `wait_for_qcx` |

发现了但**没有修改**的问题（属于行为变更，需要真机验证后再定）：

| backend | 问题 |
|---|---|
| qcarcam | 每个 stream 的 `buf_list.id` 都被设为同一个常量 `QCARCAM_BUFFERLIST_TYPE`（5），但注释写的是“stream 序号”。多 stream 时，`FRAME_READY` 的帧只会路由到第一个 stream |
| qcarcam | `on_frame_ready()` 在回调线程里遍历 `streams_` 时没有加锁，而 `stop_camera()` 会清空 `streams_`；停机时存在竞争 |
| qmmf | `stop_camera()` 会删除所有还在流转中的 frame。listener 如果用 `acquire_ref()` 持有了某帧，又在停机之后才 `release_ref()`，就会访问已释放的内存。约定：停机前必须释放所有引用 |
| qmmf | `StartCamera(camera_id, 30)` 写死 30 fps，不使用 stream 参数里的帧率 |

## 6. 管理层 `qrb_camera::CameraManager`

```cpp
struct CameraEntry { std::string backend; std::string id; std::string description; };

class CameraManager {
public:
  explicit CameraManager(std::vector<std::string> manual_backends = {},
                         std::vector<std::string> plugin_paths = {});
  std::vector<CameraEntry> list_cameras() const;
  std::string default_backend() const;                       // backend 名；没有默认项时为空
  int  create_camera(uint32_t camera_id, const std::string & backend = "");
  bool set_camera_parameter(int index, CameraConfigure & param);
  bool register_callback(int index, ImageCallback image_cb);
  bool start_camera(int index);
  void stop_camera(int index);
  bool destroy_camera(int index);
  int64_t device_now_ns(int index) const;
};
```

构造时：

- `plugin_paths` 为空时，依次用 `$PLUGIN_DISCOVERY_PATH`、编译进去的 `plugin_discovery_plugin_dir(camera)`（deb 里是 `/opt/ros/jazzy/share/camera/plugins`）。
- 然后执行 `registry_.scan()` 和 `backends_ = registry_.load<ICameraBackend>(manual_backends)`。
- 最后把加载结果汇总打印一次：`how`、每个已加载的 backend 和它的设备、每个被跳过的 backend 和原因。

`create_camera(camera_id, backend)` 的规则：

1. `backend` 不为空：在已加载的 backend 里找这个名字（和 `name()` 比较），找不到就失败。
2. `backend` 为空：用 `backends_.first`。如果它不在已加载列表里，就失败，日志写出原因（`missing`、`unsupported`、`fault`、`incompatible`、`load_failed`）。
3. `camera_id` 必须在这个 backend 报出的设备里；声明了 `unlisted_ids` 的 backend 不校验，打开失败留到 `init()` 或 `start_camera()` 再报。
4. 同一个 backend 和 id 不能重复创建。
5. 调 `open(DeviceInfo)`，返回 index。

生命周期：`registry_` 和 `backends_` 声明在 `devices_` 之前，所以析构时设备先销毁，backend 和它的 `.so` 后卸载。`destroy_camera()` 依次 stop、移除 listener、销毁设备。

## 7. ROS 节点 `qrb_ros_camera`

| 参数 | 默认值 | 说明 |
|---|---|---|
| `camera_backend` | `""` | 为空时由配置决定；不为空时作为人工指定传给 `CameraManager`，只加载这一个 backend（效果同 `PLUGIN_DISCOVERY_BACKEND_CAMERA`） |
| `camera_id` | 必填 | 这个 backend 自己的相机 id（A7） |
| `stream_size`、`stream_name`、`<stream>.width/height/fps`、`camera_info_path` | 同现有实现 | 不变 |

构造顺序：解析参数 → `CameraManager(manual)` → `create_camera` → 计算时间偏移 `offset = ros_now - device_now_ns()` 并启动每秒一次的定时器 → `set_camera_parameter` → `register_callback` → `start_camera`。

- 任何一步失败都 throw，让 `component_container` 加载失败，不留下一个“活着但不出帧”的节点。
- 时间戳转换沿用 IQ10 的做法，包括下溢时截到 0。
- **时间偏移每秒重新计算一次**（ROS wall timer，结果存放在 `std::atomic<int64_t>` 里，发布图像时读取）。原因：ROS 时间就是系统时间，会被时间同步服务（NTP、gPTP）调频，也可能发生跳变；而 QTimer 是不受调整的硬件计数器。2026-11-23 在 IQ10 上实测漂移约 33 ppm（只算一次偏移的话，每小时累积约 120 ms 误差）。每秒重算之后，漂移误差最多约 33 us；系统时间发生跳变时，最多影响 1 秒内的帧，偏移变化超过 1 ms 会打 WARN。不在每帧都算，是为了避免在相机回调线程里去拿 `CameraManager` 的锁（`start_camera` 期间这把锁一直被持有）。IQ9 的 `CLOCK_BOOTTIME` 和系统时间一样会被调频，所以不会漂移，但同样会受跳变影响，因此也一并受益。`qrb_ros_camera_IQ10` 做了同样的修改。
- 删掉 `CameraType` 和按 backend 名字切换时钟的分支。
- launch 合成一份：在 IQ10 版的基础上加 `camera_backend` 参数，测试节点默认关闭（`enable_test_node:=false`）。`camera_info_path` 沿用 IQ10 的默认值 `share/qrb_ros_camera/config/camera_info_OX03F10_yuv.yaml`：它只填充 `camera_info` 话题，不影响出帧；需要准确内参时再指定。

## 8. 配置与部署

### 8.1 平台配置是怎么选出来的

`platform-detect`（随 plugin_discovery 安装，由 systemd 在第一次开机时运行一次）读取 `/sys/devices/soc0/machine` 和 `/etc/os-release`，拼出前缀 `lower(machine)-ubuntu-`，在 `/usr/share/plugin_discovery/platforms.d/` 里按**文件名**查找。规则如下：

- 只忽略大小写，其他必须完全一致。
- 命中的文件链接成 `/etc/plugin_discovery/platform.d/<域>.config.yaml`。
- 没有命中时，这个域保持未配置，库会加载所有兼容的 backend。这时默认项按插件名排序，是 `camera/QCarCamCamera`，**IQ9 上会因此失败**。所以候选文件名必须和板子上读到的 machine 一致。

### 8.2 `qrb_camera_platform_config`

```
qrb_camera_platform_config/
├── CMakeLists.txt     把 config/*.config.yaml 装到 ${QRB_CAMERA_CANDIDATES_DIR}
│                      （默认 ${CMAKE_INSTALL_DATADIR}/plugin_discovery/platforms.d；
│                        debian/rules 传入 /usr/share/plugin_discovery/platforms.d）
├── package.xml
├── config/
│   ├── QCS9075-Ubuntu-camera.config.yaml     domains.camera.backends: [qmmf]
│   └── QAM8797P-Ubuntu-camera.config.yaml    domains.camera.backends: [qcarcam]
└── debian/            postinst 和 postrm 运行 platform-detect --force（同 plugin_discovery 的
                       packaging/config/platform）
```

- machine 值：IQ10 `QAM8797P`（2026-11-22 真机确认），IQ9 暂定 `QCS9075`（C1，待确认）。装到真机后，用 `/var/lib/plugin_discovery/platform-detect.done` 或 `platform-detect --dry-run` 核对。
- 候选文件只写 backend 名，不写 camera id、分辨率或标定文件，这些属于 `qrb_ros_camera` 的参数。

### 8.3 移交给平台 owner

文件名、目录和内容都和 plugin_discovery 的 `packaging/config/platform`（`-DPD_MACHINE … -DPD_CAMERA_BACKENDS …`）一致，平台 owner 可以原样接手。移交时要注意：两个 deb 不能安装同名的候选文件，否则 dpkg 会报文件冲突。所以平台 owner 的包发布后，本仓库要么删除 `qrb_camera_platform_config`，要么给它加 `Replaces:` 和 `Breaks:` 后停止更新。

**移交后本仓库要做的事**（C++ 代码不用改：`CameraManager` 只调用 `PluginRegistry::scan()` 和 `load()`，配置文件由谁提供、放在哪里，它都不关心）：

| 要做的 | 说明 |
|---|---|
| 删除 `qrb_camera_platform_config/` | 或者按上面的做法加 `Replaces:` 和 `Breaks:` |
| README、VERIFY 第 4 节改成安装 plugin_discovery 的平台配置包 | 例如 `-DPD_MACHINE=QAM8797P -DPD_CAMERA_BACKENDS=qcarcam` 打出来的 deb |
| **backend 名作为对外契约保持不变** | 平台配置里写的是 `qmmf`、`qcarcam`，也就是清单里的 `BACKEND`。以后改 backend 名，就等于要求平台 owner 同步改配置 |

### 8.5 编译期写入配置（LE / QLI，只读根文件系统）

> **状态：暂缓**（2026-11-22 决定）。当前只做 LU（Ubuntu），先在 LU 上验证整套代码；等 plugin_discovery 的 recipe 写好后，再按本节做 LE 适配。下面是届时要核对的内容。

LE 上每个 machine 一个镜像，根文件系统只读，运行时不能执行 `platform-detect` 去建链接。所以平台配置要在**镜像构建时**就确定下来（例如 Yocto recipe 根据 `MACHINE` 选好文件，直接安装到 plugin_discovery 读取的平台层目录）。

**本仓库的 C++ 代码不需要改**，原因：
- `CameraManager` 只读配置，不写任何文件，也不依赖 `platform-detect`、stamp 文件或 `/etc` 下的链接。
- 默认清单目录 `QRB_CAMERA_PLUGIN_DIR` 来自 `CMAKE_INSTALL_FULL_DATADIR`。Yocto 用 `prefix=/usr` 加 `DESTDIR` 安装，得到的是目标机上的 `/usr/share/camera/plugins`，正确。
- backend 选择规则（第一项为默认、不回退、人工指定覆盖）都由 plugin_discovery 实现，与配置是运行时链接还是编译期安装无关。

**需要和 plugin_discovery 对齐的约定**（这些地方一变，本仓库就要跟着改）：

| 约定 | 本仓库依赖它的地方 | 如果 plugin_discovery 改了 |
|---|---|---|
| 配置格式（`domains.camera.backends` 等） | 平台配置文件、测试 | 跟着改配置文件 |
| 读取配置的目录 | 不直接依赖 | 不用改 |
| **运行时覆盖配置目录**（`PLUGIN_DISCOVERY_CONFIG_PATH`，或 `PluginRegistry` 构造函数的 `config_paths`） | `camera_manager_test` 和 VERIFY 6.5/6.6 用它注入测试配置 | **请保留**；如果去掉，`CameraManager` 需要增加 `config_paths` 参数并改测试 |
| 人工指定（`PLUGIN_DISCOVERY_BACKEND_CAMERA`、`load(manual)`） | 节点的 `camera_backend` 参数、VERIFY 6.1/6.2 | **请保留** |

**如果平台配置仍然留在本仓库，需要补的**：

| 要做的 | 说明 |
|---|---|
| QCLinux 的配置 | 文件名中的 OS 类型是 `QCLinux`，例如 `QAM8797P-QCLinux-camera.config.yaml` |
| CMake 增加“直接安装选定配置”的方式 | 例如 `-DQRB_CAMERA_PLATFORM_CONFIG=QAM8797P-QCLinux`：直接把这一份安装成平台层的 `camera.config.yaml`，不再安装全部候选文件 |
| 不安装 debian 的 postinst/postrm | LE 不用 deb，也没有 `platform-detect` |

具体目录和 CMake 变量名，要等 plugin_discovery 的编译期配置方案定下来再定。

### 8.4 客户配置

客户把 `NN-camera-<来源>.config.yaml` 放进 `/etc/plugin_discovery/config.d/`。规则（`backends`、`disable`、`reset`）见 plugin_discovery 的 `docs/TEMPLATES.md`，本仓库不另外定义。

## 9. 运行时流程（IQ10）

```
第一次开机 → platform-detect：
    /etc/plugin_discovery/platform.d/camera.config.yaml → QAM8797P-Ubuntu-camera.config.yaml
ros2 launch qrb_ros_camera ... camera_id:=11
  CameraNode
    → CameraManager()：scan() 读清单和配置 → 最终列表 [qcarcam]，first = camera/QCarCamCamera
    → load<ICameraBackend>()：只 dlopen qcarcam 的 .so（qmmf 不在列表里，不会 dlopen）
         → 版本/ABI 校验 → probe() → Ok {11, 6, ...}
    → create_camera(11, "") → first → open({11}) → init → set_param → start_camera
    → 帧 → publish（时间戳经 device_now_ns() 换到 ROS 时钟）
```

## 10. 测试与验证

| 阶段 | 内容 | 环境 |
|---|---|---|
| P1 | `camera_interface`、`qrb_camera`。用 fake backend（plugin_discovery 的宏注册）测：默认项、人工指定、first 是 missing/unsupported/fault 时失败、未知 id、`unlisted_ids`、重复创建、析构顺序 | x86，不需要 SDK |
| P2 | 移植两个 backend，实现 `probe()` | 真机，或用 fake SDK |
| P3 | ROS 节点和 launch | x86 只编译，运行在真机 |
| P4 | 平台配置包。用 `platform-detect --dry-run --machine-file --os-release` 模拟 IQ9 和 IQ10，用 `pluginlib-detect -d camera` 检查合并结果 | x86 |
| P5 | 真机矩阵：IQ9 和 IQ10 各测「无配置 / 平台配置 / 平台配置加客户配置 / `camera_backend` 人工指定」；负面用例：IQ9 上人工指定 qcarcam 必须明确失败、不能崩溃 | device |

通过标准：收到帧，且 ROS 时间戳正确。只看到“probe 成功”不算通过。

## 11. 风险与待办

| # | 事项 | 状态 |
|---|---|---|
| C1 | 两块板 machine 字符串的真实值 | IQ10 `QAM8797P` 已确认；IQ9 暂用 `QCS9075`，待核对 |
| C4 | **IQ10 冷启动时 QCX server 可能还没就绪**：qcarcam 的 probe 报 Fault，节点启动失败。原代码检查 `/dev/mqueue/QCX_debfcadf` 并不可靠（可能读不到），已注释掉，本设计也不使用 | **低优先级**（2026-11-23）：`qcx_server` 开机自启动，节点不随开机启动，是之后手动或由应用启动的，届时 QCX 已就绪，竞态不会发生。只有把节点做成开机自启动时才有影响：unit 需加 `After=qcx_server.service` 和 `Wants=qcx_server.service`（README 已写明）。probe 内的有限重试等到真有开机自启动需求时再做 |
| R4 | Ubuntu 镜像上 `apt install` 之后，needrestart 会自动重启平台服务；而 `qcx_server.service` 的 `ExecStartPre` 调用的 `restorecon` 在这个镜像上不存在，QCX 一旦被重启就再也起不来（2026-11-22 在 IQ10 上遇到，之后重刷了 AU build） | 验证时不用 apt 装本地 deb，改用 dpkg（VERIFY “原则”一节）。正式发布的 deb 也要考虑：用户 `apt install` 时同样会触发 needrestart，需要反馈给平台 owner |
| R5 | **同一进程里多个相机节点时，QCarCam 会被初始化多次**：每个节点有自己的 `CameraManager`，各自创建 `QCarCamBackend`，`initialized_` 只在单个实例内有效；先卸载的节点调用 `QCarCamUninitialize`，会让另一个节点的会话失效 | 待定：有“一个进程开多路相机”的需求时，改成 backend `.so` 内的进程级引用计数 |
| R6 | **运行中出现致命错误，节点不会知道**：QCarCam 的 `QCARCAM_ERROR_FATAL` 只把 `running_` 设为 false，QMMF 的 `kCameraError` 只打日志，`FrameListener::on_error()` 也只打日志；节点活着但不再出帧 | 待定：取决于产品需求（节点退出还是只打报警） |
| R7 | **buffer 在回调返回后被覆写，两块板都存在**：节点发布的是 backend buffer 的 fd。QCarCam 回调返回后把 buffer 还给驱动；QMMF 也一样，因为 `FrameListener` 没有调用 `acquire_ref()`，分发结束时引用计数归零，buffer 立即还给 recorder。订阅方处理慢或消息排队时，会读到后面的帧 | 暂不处理（2026-11-23）。可选方案：dup fd、可选的复制模式，或者让订阅方用完再归还 buffer（引用计数） |
| R3 | QCX server 在节点运行期间重启，backend 持有的 QCarCam 会话失效 | 和 C4 同属“QCX 可用性”问题，后续一起处理；目前要重启节点 |
| R1 | plugin_discovery 还是 0.x，标为“暂定”的行为可能会变 | `find_package(plugin_discovery 0.3 REQUIRED)` 锁定版本 |
| R2 | 统一镜像里 qmmf 的 `.so` 在 IQ10 上缺少运行时依赖 | 不在配置列表里就不会 dlopen；只有“无配置”时才会出现 `load_failed` |
