<div align="center">
  <img src="assets/github/hero-v2.gif" alt="HomePlay：从眼睛特写拉远到 Mac 桌面上的一台小 HomeView" width="720">
  <h1>HomePlay</h1>
  <p><strong>它会看着你，并将 CarPlay 带到 Mac 上。</strong></p>
  <p>把 HomeView 做成 Mac 上的桌宠，让你在实体发售之前，率先体验 HomeView software 的交互。</p>
  <p><a href="README.en.md">English</a> · <a href="https://homeplay.aaronlau.me/zh-hans/">产品页面</a></p>
  <p>
    <a href="https://github.com/surfine/HomePlay/releases/latest"><img src="https://img.shields.io/github/v/release/surfine/HomePlay?label=download&style=flat-square" alt="最新版本"></a>
    <img src="https://img.shields.io/badge/macOS-14%2B-15181c?style=flat-square" alt="macOS 14+">
    <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-15181c?style=flat-square" alt="Apple Silicon">
    <img src="https://img.shields.io/badge/Swift-RealityKit-2a63d4?style=flat-square" alt="Swift + RealityKit">
    <img src="https://img.shields.io/badge/license-GPL--3.0--or--later-2a63d4?style=flat-square" alt="GPL-3.0-or-later">
  </p>
</div>

> 个人实验项目，与 Apple Inc. 无关，也未经 Apple 认证或背书。CarPlay 与 HomeView 是 Apple Inc. 的商标，这里只用来说明兼容性。请自行评估使用风险。

## ⭐️ Features

- **插线连接，然后无线。** 如同妙控系列配件一样的配对体验：第一次用数据线连上 Mac，配好就自动换成无线，之后拔线 CarPlay 也不会断。
- **十种表情和多款表盘。** 初步设计了十种表情和多款表盘（Liquid Glass 大数字、Flow 泡泡字、模块、指针、床头夜灯……），旨在为平凡的日常注入一丝活力，帮助你收获更多平静、自在和从容。
- **稍微用力按下屏幕，就是 CarPlay。** 在 Mac 桌面上获得连贯的 CarPlay 车载体验。与 iPhone 镜像不同的是，你可以通过 Mac 访问 iPhone 上的 Siri：按住 F5 直接开口说话，全程免提操作，在工作时减少分心。
- **不只是 CarPlay。** 还整合了番茄钟、电量显示和“正在播放”小组件，并支持窗口置顶，相当于 iTunes 迷你播放器，但播的是 iPhone 上的曲库，比 AirPlay to Mac 更灵活和主动（F7–F9 媒体键切歌）。

<img src="assets/github/grid-v2.webp" alt="HomePlay 正面、背面、真实 CarPlay 音乐画面与拆开图" width="100%">

| 多款表盘 | 十种表情 |
|:---:|:---:|
| <img src="assets/github/styles-v2.webp" alt="岛、Flow、模块、指针、岛的口袋与床头夜灯六款表盘" width="100%"> | <img src="assets/github/faces-v2.webp" alt="同一双眼睛做出的十种表情" width="100%"> |

<img src="assets/github/finishes-v2.webp" alt="G4 白、银、星光、玫瑰与深空灰五种外观" width="100%">

## 💡 使用前须知

- **测试过的 iPhone：** 只测试了运行 iOS 15、配备 Lightning 接口的 iPhone SE（第 1 代）和运行 iOS 27、配备 USB-C 接口的 iPhone 18 Pro，其他机型待反馈。
- **手势：** 双指张合以缩放，双指滑动以旋转，三指拖移换位置。
- **跟着你转：** 右键菜单还有一个类似 iMac G4 广告的 DockKit 跟随效果，并可匹配室内光线。

## 🧑🏻‍💻 开发者的话

> “👀”是我很喜欢的一个 emoji，可以用来表达兴奋和期待。唐老鸭是我最喜爱的卡通角色之一，一双灵动的大眼睛，呆萌呆萌的，可爱极了。
>
> 私以为在 AI 时代，拥有好奇心、释放想象力、发挥创造力、保持判断力和锻炼协同能力是至关重要的。希望 HomePlay 这只桌宠能带给大家一些乐趣。

## 安装

**需求：** macOS 14 以上、Apple Silicon。

[**下载 HomePlay-macOS-arm64.zip**](https://github.com/surfine/HomePlay/releases/latest/download/HomePlay-macOS-arm64.zip)，然后：

1. 解压，把 `HomePlay.app` 拖进「应用程序」。
2. 打开。桌宠会带着时间与眼睛出现；不需要账号、配置文件或任何设置。
3. 第一次用 CarPlay：用 USB 线把 iPhone 连到 Mac 一次，在 iPhone 上点「信任」与「配对」。
4. 重按桌宠进入 CarPlay。配对稳定后拔线会自动切到无线。

Release 有 Developer ID 签名并通过 Apple 公证，解压后 Gatekeeper 会直接放行。对应的 checksum 是 [`HomePlay-macOS-arm64.zip.sha256`](https://github.com/surfine/HomePlay/releases/latest/download/HomePlay-macOS-arm64.zip.sha256)，可用 `shasum -a 256 -c HomePlay-macOS-arm64.zip.sha256` 验证。

## 0.6.1 的新东西

- **系统自己的 Liquid Glass：** 表盘大数字直接用 macOS 27 画 Liquid Glass 的那套引擎，折射、厚度、沿轮廓的亮边都和系统一样；Flow 的亮边会跟着你转。
- **字体与颜色：** 照 iOS 27 锁定画面——六款系统时钟字体加粗细滑杆、色票（或跟随壁纸）加色调滑杆、玻璃或实线；右键 › 表盘 › 字体与颜色，或在设置 › 外观里打开。
- **系统时钟数字：** 改用 iOS 锁定画面同一套数字字体，长高时笔画不变形；修掉了「9」里面那条细线。
- **更省电：** 闲置 CPU 从约 9% 降到约 5%。

[完整 Release notes](https://github.com/surfine/HomePlay/releases/tag/v0.6.1)

## 特色（技术细节）

- **真的 CarPlay**：无线（蓝牙 iAP2 到 Wi-Fi）或有线 USB；H.264 与 HEVC；触控回传；声音走 Mac 扬声器；iPhone 的「正在播放」接到 Mac 系统 Now Playing 与控制中心。
- **从官方产品出发**：Apple 官方 HomeView USDZ 几何与材质、五种机身外观、背面 USB-C 母座；RealityKit 实时渲染与 Quick Look 同级 IBL。
- **安静、省电**：闲置后换成静态海报，ARView 离开画面；被遮住或屏幕休眠时停止渲染。没有通知、没有反馈、没有 telemetry。
- **零设置**：自动取得当前 Wi-Fi、自动匹配手机、插线与拔线自动切换；不读系统钥匙串，不弹管理员密码。
- **面向公开**：单一实例、VoiceOver 可按、英／简／繁、权限说明本地化、GPL 开源。

## 运作方式

```mermaid
flowchart LR
  iPhone[iPhone CarPlay] -- "USB / Wi-Fi + iAP2" --> Receiver[homeplay-receiver]
  Receiver -- "WebSocket H.264 / HEVC" --> Pet[homeplay-pet, RealityKit]
  Pet -- "HID touch" --> Receiver
```

## 手势

<details>
<summary>全部手势</summary>

| 动作 | 结果 |
|---|---|
| 拖动、双指滑 | 转身体 |
| 三指拖移、⌘ 拖动 | 移动位置（直播时拖边框） |
| 捏合、⌘+、⌘−、⌘0 | 放大缩小（⌘0 归位） |
| 重按 | 进入／退出 CarPlay |
| 长按屏幕 | 切换表盘 |
| 双击 | 角度回正 |
| 双指轻点两下 | 拆开／装回 |
| ⌘H | 隐藏桌宠（状态栏图标可再显示） |

</details>

## 隐私与权限

HomePlay 不连任何服务器，没有账号，也没有 telemetry。权限按功能逐项申请：

| 权限 | 什么时候会问 | 拒绝后 |
|---|---|---|
| 相机 | 开启「跟随我」或「房间光线」时 | 桌宠本身照常使用 |
| 麦克风 | 第一次进入 CarPlay 通话／Siri 时 | CarPlay 画面与触控仍可用 |
| 蓝牙 | 第一次配对 iPhone 时 | 可用 USB 连接 |
| 局域网 | 接收 iPhone 的 CarPlay 画面时 | 无法使用 CarPlay |
| 日历 | 开启日历表盘时 | 其他表盘照常使用 |
| Automation | 开启 Mac Now Playing 时 | 其他功能照常使用 |

相机画面只在本机处理，不存档、不上传。无线 CarPlay 需要 Wi-Fi 凭据时，由用户在菜单中填一次，存成本机 0600 文件；不读系统钥匙串。

## 从源代码编译

需要 macOS 14 以上与 Swift 6 工具链。

公开源代码快照**不包含** Apple 的 HomeView USDZ。请把 `apple-homeview.usdz` 放进 `Sources/homeplay-pet/Resources/`，否则机身不会加载。签名的 Release 已内置。

```sh
swift build -c release
B=.build/release

$B/homeplay-receiver --source auto --ssid '<Wi-Fi 名>' --port 8788
$B/homeplay-pet --endpoint ws://127.0.0.1:8788

$B/session-tests && $B/iap2-offline-tests
```

自己编译且要用 CarPlay 时，请准备 `identity.pk8` 与 `certificate.p7b`，用 `--identity-dir <目录>` 或环境变量 `HOMEPLAY_IDENTITY_DIR` 指定。只用桌宠、或使用 `--source window`／`h264` 时不需要身份。工具不会打印或上传身份内容。

| 目标 | 是什么 |
|---|---|
| `homeplay-pet` | 3D 桌宠（RealityKit + Apple USDZ），屏幕接接收器直播，触控回传 |
| `homeplay-receiver` | 接收器：`auto`（有线／无线）、`wireless`、`usb`、`window`、`h264` |
| `homeplay-verify` | 扮成客户端连接收器，解出一帧存 PNG |
| `session-tests` / `iap2-offline-tests` | 会话层与 iAP2 的离线测试 |

## 文档

| 文档 | 内容 |
|---|---|
| [无线连接与配对](docs/wireless.md) | iAP2 握手、可选的 Wi-Fi 凭据与疑难排解 |
| [性能与能耗](docs/performance.md) | 渲染循环、闲置行为与耗电测量 |
| [房间光线](docs/room-light.md) | 可选的相机光线估计 |
| [HomeView 研究](docs/homeview-study.md) | 比例与官方 USDZ 结构 |
| [CarPlay 实现笔记](docs/carplay-best-practices.md) | 接收器实现与边界情况 |

历史实拍与设计稿在 [`docs/evidence/`](docs/evidence/) 与 [`docs/design-drafts/`](docs/design-drafts/)；它们是历史资料，不是当前产品截图。

## 配件身份（只限源代码编译）

签名的 Release 已内置公开实验性配件身份，安装后即可使用，不需要另外准备文件。公开的源代码快照不包含这个身份。自己从源代码编译且要用 CarPlay 时，请自备 `identity.pk8` 与 `certificate.p7b`；来源与合法性由用户自行负责。工具不会打印身份内容。

## 致谢与授权

GPL-3.0-or-later，见 [`LICENSE`](LICENSE)。CarPlay 会话控制面参考 MacPlay 与 LIVI 的行为，以 Swift 重新实现；致谢与版权见 [`NOTICE`](NOTICE)。

HomePlay 是个人实验项目，与 Apple Inc. 无关。CarPlay 与 HomeView 是 Apple Inc. 的商标，这里只用来说明兼容性。

这个仓库是从私有开发仓库定期同步的精选快照，所以历史是一次一个同步提交。

## 回馈

请开 [issue](https://github.com/surfine/HomePlay/issues)。没有支持 SLA，但可复现的报告会读。
