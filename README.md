# VirtualCamPro

[![Build rootless package](https://github.com/GUSHU101/VCamLab-2.0/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/GUSHU101/VCamLab-2.0/actions/workflows/build.yml)
[![Source validation](https://github.com/GUSHU101/VCamLab-2.0/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/GUSHU101/VCamLab-2.0/actions/workflows/test.yml)

VirtualCamPro 是面向 **rootless 越狱 iOS 15** 的系统级虚拟摄像头/麦克风插件。SpringBoard 进程只生成一份媒体流，`mediaserverd` 在 `CMCapture` 相机媒体图的 `BWNodeOutput` 处替换真实 `CMSampleBuffer`；照片、录像、视频通话、WebRTC 与扫码等下游因此读取同一份替换样本，而不是在界面上覆盖一层图片。

当前版本：`2.24.2`

> 正式 `.deb` 由 GitHub Actions 从当前提交构建并作为 `VirtualCamPro-rootless` artifact 发布；不要混用历史 2.8.0 二进制。

## 功能

- 单生产者架构：只有 SpringBoard 负责屏幕捕获、网络拉流或本地媒体解码；`mediaserverd` 和应用进程不再各自拉流/解码。
- 系统相机图替换：`mediaserverd` 在所有可识别的 `BWNodeOutput` 颜色/PCM 节点替换真实样本；压缩辅助流、深度、视差和元数据始终透传。
- 逐样本自动回退：系统 Hook 给实际替换成功的 sample/pixel buffer 写可传播证据；应用内 `AVCaptureVideoDataOutput` 和音频输出只旁路该具体样本，预览与照片不会再被其他 CaptureSession 的全局心跳误关闭。限频健康状态仅用于诊断，不再决定正确性。
- 连续本地音频：每个系统节点和应用输出拥有独立 PCM 游标、约 30 ms 抗抖储备及带相位/前视样本的连续重采样上下文，多 CaptureSession 不会互相抢读或在 44.1/48 kHz 回调边界跳样。
- 零拷贝进程间视频：SpringBoard 保留 3 槽全局 IOSurface；常驻控制 IOSurface 与 Darwin notify 直连状态构成冗余发现通道，消费者映射同一物理内存，不复制或序列化帧。iOS 15 沙箱无法映射控制面时会自动走直连元数据，不再把“生产者稳定产帧”误当成“消费者已可见”。
- 本地媒体：MP4/MOV 等视频可同时替换摄像头和麦克风；纯 MP3/M4A 只替换麦克风，画面继续使用物理摄像头。
- 原生媒体选择：在“替换来源”选择“手机本地视频 / 音频”后，点击“选择本地视频 / 音频”，可从“文件”批量选择视频/音频，或从“照片”一次选择多段视频；无需手工输入路径。导入时会从文件内容类型补齐提供器临时文件缺失/错误的媒体后缀，并在同一个 30 秒预算内用全新的 `AVURLAsset` 对瞬时空轨道结果重试一次。方向/尺寸只在首次播放前准备并供循环复用，再原子保存到 `/var/mobile/Media/VirtualCamPro/`。
- 屏幕镜像：SpringBoard 通过 CoreAnimation 直接渲染到 IOSurface，再交给系统相机管线。
- HLS：URL 中包含 `.m3u8` 时使用 `AVPlayerItemVideoOutput` 解码；轮询频率按发送端 nominal FPS 自适应，不再让 30/60 FPS 流固定消耗 240 Hz 主线程轮询。
- MJPEG：其他 HTTP/HTTPS URL 按连续 JPEG 流解析；增量校验 JPEG 段结构、直接读取 SOF 尺寸并限制单帧与接收缓冲。优先尝试实时 VideoToolbox→IOSurface NV12 解码，不支持时自动回退 ImageIO。
- 网络流参数透传：手机不旋转、镜像、限帧、缩略或重编码网络帧，分辨率、方向、帧率和质量由 Windows/OBS 发送端决定；网络模式不发布替换音频，始终使用手机原生麦克风。
- 无日志运行诊断：设置页用低频进程心跳排除历史 notify 假状态，并直接显示 SpringBoard 共享视频总线、mediaserverd Hook/取帧/转换/替换以及真实 AVFoundation 代理/预览/照片回退活动；共享读取失败会细分到控制面、直连状态、帧 IOSurface 查找、包装和发布竞争，切回设置后仍可复制最后阶段和发生时间。
- 运行状态与恢复：设置页直接显示 SpringBoard 来源产帧状态、mediaserverd 系统视频接管状态和应用回退状态，并可在不改变任何来源参数的情况下原子重载当前生产者。
- 来源故障隔离：屏幕、本地文件和网络来源的错误/完成回调都绑定当前 generation；切换后迟到的旧回调不能覆盖新来源状态。非循环本地媒体自然结束时会立即清空共享 PCM、恢复原生麦克风，并在控制面板显示“播放完成”。
- 手机控制面板：以 iOS 15 原生 PreferenceLoader 行作为稳定主界面；页面完全出现后才刷新只读状态，离开设置立即停表。若私有 Preferences.framework 行刷新发生异常，会自动停用动态刷新并保留静态设置功能，不再拖垮 Settings。来源操作指引、本地媒体库容量/文件清单、缺失文件提示和脱敏诊断复制仍集中在同一页面。
- VideoToolbox 像素转换：输出尺寸、像素格式和时间戳跟随真实相机原始帧。
- 转换结果缓存：多个来源代次和相机图节点可复用已转换像素缓冲；池/缓存锁与 VideoToolbox session lane 分离，lane 繁忙时同目标节点复用最近完成帧而不阻塞媒体图。缓存使用 LRU 且硬限制为 64 MiB，兼顾 A10 连续性与内存稳定。
- 媒体图热分发：`BWNodeOutput` 原始实现按运行时类写入 128 槽无锁正向缓存，正常帧不再重复遍历类继承链和 Hook 表；动态加载的新子类仍会刷新对应项。
- 节点与格式隔离：仅处理声明为视频的颜色像素输出；只有本地媒体发布的 PCM 才替换麦克风，网络/屏幕音频、深度、视差和压缩样本原样透传。
- 内存压力恢复：iOS 警告或严重内存压力时释放转换帧、像素池和 VideoToolbox 会话，下一帧自动重建。
- 自动重连与看门狗：首帧或后续帧超时时主动重建连接，退避最长 30 秒。
- 最新帧优先：MJPEG 接收和 JPEG 解码分队列运行，解码器只保留一个最新待解码帧；共享发布也只保留最新待处理帧，避免网络读取被解码阻塞或队列越积越旧。
- 原子化流切换：URL、本地文件或本地方向改变后，旧连接、旧 reader 和旧变换的在途帧会被丢弃。
- 可配置断流策略：保持最后一帧，或在设定超时后恢复真实相机。
- rootless 打包，同时构建 `arm64` 和 `arm64e`。
- 设置修改通过 Darwin 通知实时传递；安装/卸载二进制时才需要重启 SpringBoard 与 `mediaserverd`。
- 应用范围选择：设置页可按名称或 bundle ID 多选目标应用。空列表保持全局兼容模式；非空列表只在选中应用的 `AVCaptureSession`/`ARSession` 活跃时打开系统替换。`UIImagePickerController` 与网页摄像头可分别选择系统 Camera 和 WebKit 内容进程。
- 本地视频控制：先读取文件自身的 `preferredTransform`，再叠加 0°/90°/180°/270° 用户旋转和最终画面水平镜像；最高 FPS 与 1280/1920/2560/3840 解码质量也只作用于本地文件。设置页会显示 SpringBoard 首帧实际应用状态。
- 音量键播放列表：稳定目录中至少有两段视频时，音量加/减切换按文件名排序的下一段/上一段；每次按键重新扫描播放列表、持久化选择并直接重建 SpringBoard reader。设置页会显示视频数量和已安装的按键 Hook 路径；不足两段时保持系统音量行为。
- OBS 工作流：Windows 工具默认自动读取当前 OBS Profile 已保存的基础画布、输出分辨率和 FPS，并与实际 DirectShow 发布模式交叉验证；启动时按当前参数实测编码余量，只有可真正创建并达到实时余量的 Intel Quick Sync MJPEG 会话才会自动接管。启用 OBS 自带的密码保护 WebSocket 后，还可在不关闭 OBS 的情况下自动启动/刷新 Virtual Camera。
- 一键手机配置：在 `VirtualCamPro-Windows-Control-Center/` 中运行 `install-phone.bat --setup 手机IP`，安装后自动推导电脑到手机所用网卡并写入流 URL；同时保存的 FPS 只供以后选择手机本地视频时使用，不限制网络流。
- Windows 可视化控制中心：仓库中的 `VirtualCamPro-Windows-Control-Center/` 是可直接使用的独立工具目录，双击其中的 `VirtualCamPro-Windows控制中心.bat` 即可预检、一键部署、验证安装并启动或诊断 OBS 桥接。
- 独立配套工具：源码目录保存 GUI、CLI、运行脚本、部署教程和 SHA-256 清单，不提交历史二进制；正式 Rootless 安装包由 GitHub Actions 单独构建，`tools/build-windows-standalone.ps1 -PackagePath ...` 可将已验证安装包组合进最终交付压缩包。

## 不支持的内容

- 不直接支持 RTSP 或 RTMP URL。可在电脑上转成 HLS 或 MJPEG。
- 不注册新的 `AVCaptureDevice`，也不伪造相机名称、镜头能力、设备型号或 EXIF。
- 不包含越狱隐藏、授权绕过、反调试或反分析功能。
- `BWNodeOutput` 与屏幕渲染入口是 iOS 私有实现。项目只针对 iOS 15.x，在调用前检查类、方法、函数与类型签名；不存在或不匹配时原样放行真实摄像头并自动使用应用层回退。

## 设备要求

- rootless 越狱 iOS 15.x。
- MobileSubstrate、Substitute 或提供兼容接口的注入框架。
- PreferenceLoader。
- 手机和推流电脑网络互通，或自行建立 USB 端口转发。

iPhone 7 Plus（A10）使用 `arm64` slice，项目的默认构建包含该架构。

## 快速使用

1. 下载或进入 [`VirtualCamPro-Windows-Control-Center/`](VirtualCamPro-Windows-Control-Center/)，先运行 `standalone-self-test.bat`，再双击 `VirtualCamPro-Windows控制中心.bat`，点“环境预检”和“一键部署到手机”。完整步骤见[最新部署教程](VirtualCamPro-Windows-Control-Center/DEPLOYMENT.md)。
2. 在 Windows 上安装 FFmpeg 和 OBS Studio。在控制中心点“诊断 OBS 桥接”，或在独立目录运行 `start-obs-vcam.bat --check`；确认通过后点“启动 OBS 桥接”或双击 `start-obs-vcam.bat`。工具会验证 Virtual Camera 确实输出帧，实测软件/可用硬件编码余量，再按 OBS 保存的画布和 FPS（例如 1920×1080@60）建立 MJPEG 服务。

   首次使用先在 OBS 中添加媒体源、设置循环并保存场景。建议在 OBS“工具 → WebSocket 服务器设置”中保留身份验证并启用服务器；以后即使 OBS 已经打开，脚本也能只启动或刷新 Virtual Camera，不会结束 OBS 或丢失未保存场景。未启用时，OBS 关闭状态下的一键启动仍然可用。

   命令行方式仍然保留：

   ```bat
   start-stream.bat obs landscape 1080p 1
   ```

   或循环播放一个视频文件：

   ```bat
   start-stream.bat "D:\Videos\demo.mp4" landscape 1080p 1
   ```

3. 使用 `--setup` 时电脑局域网地址已自动写入；手动安装时再查询，例如 `192.168.1.10`。
4. 手机“设置 → VirtualCamPro”中填写：

   ```text
   http://192.168.1.10:8888/live.mjpg
   ```

5. 将“替换来源”设为“网络 HLS / MJPEG”，开启“启用画面替换”；可先点“检测当前网络流”验证数据，再重新打开相机应用。屏幕镜像或本地文件则选择对应来源并填写 `/var/mobile/Media/...` 下的媒体路径。

正常情况下只需在 OBS 保存视频设置后双击 `start-obs-vcam.bat`，脚本会自动读取，不需要再执行 `--check FPS`。临时覆盖时仍可运行 `start-obs-vcam.bat 29.97`。网络 FPS、画质、分辨率和方向完全由 OBS/FFmpeg 输出决定，手机设置中的 FPS/质量/旋转/镜像只属于本地文件来源。

网络预览方向不正确时请直接在 OBS 场景或 Windows 输出画布中修正；手机不会二次旋转或镜像网络帧。本地文件方向不正确时才使用 VirtualCamPro 的本地旋转/镜像设置。

FFmpeg 的简易 MJPEG HTTP 输出一次只服务一个连接。需要多客户端或更稳定的 OBS 工作流时，推荐使用 SRS/MediaMTX 接收 OBS 的 RTMP 并输出 HLS，再填写 `http://电脑IP:端口/live/name.m3u8`。

## 统一系统管线

| 进程 | 职责 | 是否解码媒体 |
| --- | --- | --- |
| SpringBoard | 屏幕捕获、网络/本地媒体解码、本地文件方向变换、IOSurface 发布 | 是，设备上唯一一份 |
| `mediaserverd` | 在系统相机媒体图中匹配原尺寸/格式/时间戳并替换颜色或 PCM 样本 | 否 |
| 相机应用 / WebKit | 正常消费系统相机；当前样本没有系统替换证据时按该样本执行 AVFoundation 回退 | 否 |

来源尚未产生第一帧时保留真实相机输出。收到过替换帧后，默认断流保持最后一帧；若关闭“断流后保持最后一帧”，超过“旧帧超时”后恢复真实相机。网络来源会在后台持续重连。

系统只替换媒体样本，不改相机设备对象，因此应用和网页仍选择系统已有的“前置/后置相机”，不会出现名为 OBS 的新设备。照片回退会尽量从真实捕获保留 TIFF/EXIF/GPS/Apple 元数据并修正尺寸；私有元数据不能完整重写时仍优先返回虚拟主图的标准 JPEG。深度、视差、人物/语义蒙版和 HDR 增益图属于原物理场景，不会与替换主图混合。

## 项目结构

- `MediaServer.x`：系统相机图低层注入。
- `Tweak.x`：应用层自动回退注入。
- `VCSharedMediaBus.*`：跨进程 IOSurface 视频与 PCM 音频总线。
- `VCScreenCaptureSource.*`：SpringBoard 屏幕 IOSurface 生产者。
- `VCLocalMediaSource.*`：本地视频/音频统一时间线读取。
- `VCAudioSampleConverter.*`：按真实麦克风 ASBD 与时间戳重建 PCM。
- `AVAssetStreamAdapter.*`：HLS/MJPEG 接收、VideoToolbox JPEG 快路径、ImageIO 回退、丢帧遥测与重连。
- `VCJPEGParser.h`：可独立测试的增量 JPEG 帧边界解析器。
- `VCFrameConverter.*`：VideoToolbox 像素格式、尺寸和比例转换。
- `VCPreferences.*`：统一偏好读取与校验。
- `VCStreamCoordinator.*`：SpringBoard 单生产者与各进程只读消费者协调。
- `prefs/`：PreferenceLoader 设置面板。
- `scripts/validate_project.py`：项目结构与配置一致性检查。
- `VirtualCamPro-Windows-Control-Center/`：可直接下载使用的独立 Windows 控制中心源码，包含 GUI、CLI、部署教程和完整性验证；安装包从同一提交的 `VirtualCamPro-rootless` Actions artifact 获取。
- `VirtualCamPro-Windows-Control-Center/scripts/`：Windows 预检、OBS 控制、FFmpeg 推流、手机安装与验证核心工具。
- `tools/build-windows-standalone.ps1`：从专用目录可重复生成带 SHA-256 清单的发布工具。

首次安装请看[最新部署教程](VirtualCamPro-Windows-Control-Center/DEPLOYMENT.md)。完整推流方案见 [STREAMING.md](STREAMING.md)，Windows 参数与退出码见 [WINDOWS_TOOLS.md](VirtualCamPro-Windows-Control-Center/WINDOWS_TOOLS.md)，构建见 [BUILD_INSTRUCTIONS.md](BUILD_INSTRUCTIONS.md)，设计与研究结果见 [ARCHITECTURE.md](ARCHITECTURE.md)，故障排查见 [TROUBLESHOOTING.md](TROUBLESHOOTING.md)，实机验收见 [DEVICE_TEST_PLAN.md](DEVICE_TEST_PLAN.md)，版本变更见 [CHANGELOG.md](CHANGELOG.md)。

## 安全边界

仅在你拥有并获准测试的设备和应用中使用。画面替换不等于新硬件相机设备；依赖私有相机管线的行为必须在目标 iOS 小版本和具体应用上实机验证。
