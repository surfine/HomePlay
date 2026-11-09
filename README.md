# HomePlay

[English](README.en.md)
[产品页面](https://homeplay.aaronlau.me/zh-hans/2.0/)
[小工具往事](https://homeplay.aaronlau.me/zh-hans/history/)

<img src="assets/github/hero-v2.gif" alt="从眼睛的特写拉远，Mac 桌面上出现一台小小的 HomeView" width="720">

一块一直留在 Mac 桌面上的屏幕。看一眼，就知道你关心的事。要做事，就在这块屏幕上做。

让 Mac 拥有一台自己的 HomeView。眼睛会看着你。主屏幕、App 和 CarPlay 都在这台小机器里。

个人实验项目，与 Apple Inc. 无关，也未经 Apple 认证或背书。CarPlay 与 HomeView 是 Apple Inc. 的商标，这里只用来说明兼容性。

[下载 2.0 beta 6](https://github.com/surfine/HomePlay/releases/download/v2.0.0-beta.6/HomePlay-2.0-beta6-macOS-arm64.zip)
[稳定版 1.0.6](https://github.com/surfine/HomePlay/releases/download/v1.0.6/HomePlay-macOS-arm64.zip)

macOS 14 及以上，Apple 芯片。两个包都有 Developer ID 签名，并通过 Apple 公证。beta 6 是测试版，可能有错。想要稳定，用 1.0.6。GPL-3.0-or-later。

## 坐在 Mac 前

桌角有一台小机器。它看着你。下一件事、现在的歌、计时还剩多久，都在这块屏幕上。

从 👀 往下拉，回到主屏幕。拉住停一下，打开 App 切换器。长按 👀，或按住 F5，跟 ClioTalk 说话。要用你的名义发消息、加提醒或改日程时，它先念一遍。你说「好」，它才做。

空格键在 CarPlay 和主屏幕之间切换。在 CarPlay 画面上，方向键、Tab 和 Return 照车上的旋钮来用。CarPlay 回到后台以后继续播放，进度留在眼睛旁边。

有一台旧的 iPad 或手机，可以配成 SideShow。副屏显示时钟、天气、正在播放和计时器。先扫码配对。Mac 睡着以后，副屏留着最后的画面。

<a href="https://www.bilibili.com/video/BV1rTnz6YEmM/"><img src="assets/github/film-cover.webp" alt="44 秒演示：眼睛、机身和 CarPlay" width="720"></a>

这段 44 秒的片子拍的是桌宠和 CarPlay。[在 B 站看](https://www.bilibili.com/video/BV1rTnz6YEmM/)。2.0 的主屏幕在[产品页面](https://homeplay.aaronlau.me/zh-hans/2.0/)。

## 为什么要单独占一块地方

Mac 已经有桌面、窗口、通知和小组件。一件事要让你知道，通常只有两条路：你去打开那个 App，或者一条通知跳出来打断你。

2001 年，微软研究院想要第三条路。JJ Cadiz、Gina Venolia、Gavin Jancke 和 Anoop Gupta 做了 Sideshow：一块一直留在视线边上的地方。平时只放和你有关的摘要。鼠标移上去，摘要展开，你可以直接处理。处理完，回到刚才的工作。

他们把设计和公司里的使用情况写成了论文：[Designing and Deploying an Information Awareness Interface](https://www.microsoft.com/en-us/research/publication/designing-and-deploying-an-information-awareness-interface-2/)（CSCW 2002）。较早的报告是 [Sideshow: Providing Peripheral Awareness of Important Information](https://www.microsoft.com/en-us/research/publication/sideshow-providing-peripheral-awareness-of-important-information/)（MSR-TR-2001-83）。

HomePlay 把这块地方做成桌上的一台小机器。摘要、App 和操作在同一块屏幕里。Mac 的桌面、程序坞和通知中心都留着。

论文里的 Sideshow 是屏幕边缘的一条信息栏。HomePlay 里的 SideShow 是另一台旧设备上的副屏。桌上这台小机器，一直开着。

苹果把小组件放过 Dashboard，后来又放回桌面。这条线写在[小工具往事](https://homeplay.aaronlau.me/zh-hans/history/)。

## 模拟器用来测试

Xcode 的 Simulator 给开发者测试界面。HomePlay 是装好以后留在桌上的软件。主屏幕、App、ClioTalk 和 CarPlay 在同一台小机器里。鼠标、触控板、键盘都能用。触控 Mac 和 Sidecar 上，手指可以点、滑、按住、双指捏合，👀 会跟着手指。

只想看一套系统长什么样，用模拟或虚拟机更直接。

## 第一次打开

1. 下载 zip，解压，把 `HomePlay.app` 拖进「应用程序」，打开。
2. 第一次会带你选语言、权限、iPhone 和外观。
3. 要用 CarPlay：用数据线把 iPhone 连上一次，在 iPhone 上点「信任」和「配对」。之后可以拔线，改走无线。第一次没切过去，就在 iPhone 的控制中心把 Wi-Fi 关掉再打开。

CarPlay 目前在两台 iPhone 上试过：iOS 15 的 iPhone SE（第 1 代，Lightning），和 iOS 27 的 iPhone 18 Pro（USB-C）。其他机型欢迎反馈。

## 怎么操作

| 想做什么 | 2.0 beta 6 |
|---|---|
| 回主屏幕 | 从 👀 往下拉 |
| 打开 App 切换器 | 从 👀 往下拉，拉住停一下 |
| 跟 ClioTalk 说话 | 长按 👀，或按住 F5 |
| 在 CarPlay 和主屏幕之间切换 | 空格键 |
| 在 CarPlay 里移动焦点 | 方向键、Tab、Return |
| 换表盘 | 长按屏幕 |
| 打开设置 | 右键，或 ⌘, |

机身可以转、缩放、挪开。在机身上拖动或双指滑动来转，双击回正。双指张合、⌥＋滚轮，或 ⌘+ ⌘− ⌘0 来缩放。三指拖移或 ⌘ 拖动来移动。双指轻点两下，把机身拆开看。

1.0.6 里，用力按屏幕进入 CarPlay。按住 F5，是 iPhone 的 Siri。

## beta 6 里有的

完整列表在[发布说明](https://github.com/surfine/HomePlay/releases/tag/v2.0.0-beta.6)。

- 主屏幕没有 Dock。第二页是 CarPlay、天气、计时器、世界时钟、Safari、食谱、跟唱、游戏、通讯录、查找。再往后是 App 资源库。
- iPhone 上的 CarPlay App 出现在资源库的「iPhone」一栏，点一下就在 CarPlay 里打开。可以在「设置 › 外观」里隐藏。
- 跟唱、游戏、通讯录，以及家庭的温控页和摄像头。温控和摄像头需要另外安装「HomePlay Home」小帮手。公开的测试版还没附上。没装的时候，它会说明原因，并打开 Mac 的「家庭」。
- Mac 桌面上的系统小组件可以放进主屏幕，包括从 iPhone 加过来的。
- 每位家人有自己的主屏幕、外观、播放列表和提醒事项。从头像切换，也可以对 ClioTalk 说「我是…」。
- 收到 AirDrop 会弹出卡片。照片、网页和食谱可以传到 iPhone。iPhone 正连着 CarPlay 时，系统不允许 AirDrop，这时改用信息传给自己。控制中心里的「收 AirDrop」会先暂停 CarPlay，收完再接上，画面停在原来的地方。

ClioTalk 用你自己的密钥。Anthropic 或 DeepSeek 的密钥只放在钥匙串。也可以用 LM Studio 在本机跑模型，或在 macOS 26 及以上用 Apple 智能的设备端模型。默认每月 5 美元，到上限就停。声音只留在内存。回答先是临时的，你点「留下」才保存。

「认出是谁」默认关闭。打开以后，人脸在这台 Mac 上计算，只存面部特征的数字，不存照片。这些数字是通用图像特征。不要把它当成生物识别级别的门锁。最多六个人。认不出的人和访客只看到默认主屏幕。

## 测试版的限制

- Liquid Glass、设备端语音和设备端模型，要 macOS 26 及以上才完整。
- 云端的 ClioTalk 需要你自己的密钥。
- FaceTime 和「查找」由 Mac 上的 App 完成。对讲从 Mac 或隔空播放音箱播出。
- YouTube 的影片只有声音。其他来源的影片可以正常播放。
- 信息要给 HomePlay「完全磁盘访问权限」才能读取。发送用 AppleScript。没有确认送达时，它会直接告诉你，不会自动重发。
- 画面是 HomePlay 自己画的。CarPlay 的画面来自你的 iPhone。

## 开发者的话

> “👀”是我很喜欢的一个 emoji，可以用来表达兴奋和期待。唐老鸭是我最喜爱的卡通角色之一，一双灵动的大眼睛，呆萌呆萌的，可爱极了。
>
> 私以为在 AI 时代，拥有好奇心、释放想象力、发挥创造力、保持判断力和锻炼协同能力是至关重要的。希望 HomePlay 这只桌宠能带给大家一些乐趣。

## 隐私

没有账号，也不上报使用情况。会联网的功能，都是你打开之后才发生。

- 1.0 的天气表盘用大致位置向 Open-Meteo 查当地天气。
- ClioTalk 只把转写后的文字发给你选的模型。
- 歌词向 LRCLIB 查询，只发送歌名、歌手和时长。这项可以关掉。

权限按功能逐项问。

| 权限 | 什么时候会问 | 拒绝后 |
|---|---|---|
| 相机 | 开启「跟着我」或「房间光线」时 | 桌宠本身照常使用 |
| 麦克风 | 第一次进入 CarPlay 通话或 ClioTalk 时 | CarPlay 画面与触控仍可用 |
| 蓝牙 | 第一次配对 iPhone 时 | 可用 USB 连接 |
| 局域网 | 接收 iPhone 的 CarPlay 画面时 | 无法使用 CarPlay |
| 位置（大致） | 天气表盘第一次出现时 | 天气表盘显示上次的城市，或不显示天气 |
| 日历 | 开启日历表盘时 | 其他表盘照常使用 |
| 自动化 | 开启 Mac 正在播放时 | 其他功能照常使用 |
| 完全磁盘访问权限 | 读取「信息」时 | 读不到信息；其余照常 |

相机画面只在本机处理，不存档、不上传。无线 CarPlay 需要 Wi-Fi 名和密码时，由你在菜单里填一次，存成本机 0600 文件，不从系统钥匙串读取。ClioTalk 的 API 密钥是你自己贴进去的，存在钥匙串。

## 从源代码编译

这个公开仓库里的源代码是 1.0：桌宠和 CarPlay 接收器，对应稳定版 1.0.6。2.0 的主屏幕、ClioTalk 和 SideShow 在测试版 App 里。2.0 的源代码还没有放进这个仓库。

需要 macOS 14 以上与 Swift 6 工具链。公开源代码不含 Apple 的 HomeView USDZ。请把 `apple-homeview.usdz` 放进 `Sources/homeplay-pet/Resources/`，否则机身不会加载。签名的 Release 已内置。

编译要链接 libopus 和 libspeexdsp，用来解 CarPlay 电话和 Siri 的 Opus，以及上行回声消除。`brew install opus speexdsp`。也可以用 `HOMEPLAY_OPUS_LIB` 和 `HOMEPLAY_SPEEX_LIB` 指向自己编的静态库。

```sh
swift build -c release
B=.build/release

$B/homeplay-receiver --source auto --ssid '<Wi-Fi 名>' --port 8788
$B/homeplay-pet --endpoint ws://127.0.0.1:8788

$B/session-tests && $B/iap2-offline-tests
```

自己编译并且要用 CarPlay 时，请准备 `identity.pk8` 与 `certificate.p7b`，用 `--identity-dir <目录>` 或环境变量 `HOMEPLAY_IDENTITY_DIR` 指定。只用桌宠，或使用 `--source window`、`h264` 时不需要身份。工具不会打印或上传身份内容。

| 目标 | 是什么 |
|---|---|
| `homeplay-pet` | 3D 桌宠（RealityKit + Apple USDZ）。屏幕接接收器直播，触控回传 |
| `homeplay-receiver` | 接收器：`auto`（有线／无线）、`wireless`、`usb`、`window`、`h264` |
| `homeplay-verify` | 扮成客户端连接收器，解出一帧存 PNG |
| `session-tests` / `iap2-offline-tests` | 会话层与 iAP2 的离线测试 |

1.0 的表盘有岛、照片、模块、Typograph、Flow、天气、日历、陪伴的痕迹、黑色和 System 6。眼睛有十种表情，剪影各不相同。参数在 `homeplay-pet` 的 `--style` 和 `--face`。

## 文档

| 文档 | 内容 |
|---|---|
| [无线连接与配对](docs/wireless.md) | iAP2 握手、可选的 Wi-Fi 凭据与疑难排解 |
| [性能与能耗](docs/performance.md) | 渲染循环、闲置行为与耗电测量 |
| [房间光线](docs/room-light.md) | 可选的相机光线估计 |
| [HomeView 研究](docs/homeview-study.md) | 比例与官方 USDZ 结构 |
| [CarPlay 实现笔记](docs/carplay-best-practices.md) | 接收器实现与边界情况 |

历史实拍与设计稿在 [`docs/evidence/`](docs/evidence/) 与 [`docs/design-drafts/`](docs/design-drafts/)。它们是历史资料，不是当前产品截图。

## 配件身份（只限源代码编译）

签名的 Release 已内置公开实验性配件身份，安装后即可使用，不需要另外准备文件。公开的源代码快照不包含这个身份。自己从源代码编译且要用 CarPlay 时，请自备 `identity.pk8` 与 `certificate.p7b`。来源与合法性由使用者自行负责。工具不会打印身份内容。

## 致谢与授权

GPL-3.0-or-later，见 [`LICENSE`](LICENSE)。CarPlay 会话控制面参考 MacPlay 与 LIVI 的行为，以 Swift 重新实现。致谢与版权见 [`NOTICE`](NOTICE)。

HomePlay 是个人实验项目，与 Apple Inc. 无关。CarPlay 与 HomeView 是 Apple Inc. 的商标，这里只用来说明兼容性。

这个仓库是从私有开发仓库定期同步的精选快照，所以历史是一次一个同步提交。

## 回馈

请开 [issue](https://github.com/surfine/HomePlay/issues)。没有支持 SLA，但可复现的报告会读。
