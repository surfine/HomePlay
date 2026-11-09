# HomePlay

A HomeView for the Mac desktop. It sits on the desk, watches you, and runs CarPlay from your iPhone.

[简体中文](README.zh-Hans.md)
[Website](https://homeplay.aaronlau.me/en/2.0/)

<img src="assets/github/hero-v2.gif" alt="The home screen pulls back from the eyes to the whole device" width="720">

[Download 2.0 beta 6](https://github.com/surfine/HomePlay/releases/download/v2.0.0-beta.6/HomePlay-2.0-beta6-macOS-arm64.zip)
[Download 1.0.6](https://github.com/surfine/HomePlay/releases/download/v1.0.6/HomePlay-macOS-arm64.zip)

Requires macOS 14 or later, on Apple silicon. Both apps are Developer ID signed and notarized. 2.0 beta 6 is the preview. 1.0.6 is the stable build. GPL-3.0-or-later.

## Install

1. Unzip the download.
2. Move `HomePlay.app` into Applications and open it.
3. Set language, permissions, iPhone, and look when asked.

CarPlay pairs over a cable the first time. On the iPhone, tap Trust, then Pair. Unplug after the picture appears. The next connection uses Wi-Fi. If Wi-Fi does not connect, turn it off and on once in the iPhone Control Center.

Tested with an iPhone SE (1st generation, Lightning) on iOS 15, and an iPhone 18 Pro (USB-C) on iOS 27. For another phone, [open an issue](https://github.com/surfine/HomePlay/issues) with the model and the iOS version.

A 44-second film shows the desk pet and CarPlay. [Watch it on Bilibili](https://www.bilibili.com/video/BV1rTnz6YEmM/). The 2.0 Home Screen is on the [website](https://homeplay.aaronlau.me/en/2.0/).

## Daily use

| To | Do this |
|---|---|
| Go to the Home Screen | Pull down on the eyes |
| Open the app switcher | Pull down on the eyes and hold |
| Talk to ClioTalk | Press and hold the eyes, or hold F5 |
| Switch CarPlay and Home | Press Space |
| Move in CarPlay | Press an arrow key, Tab, or Return |
| Change the face | Press and hold the screen |
| Open Settings | Right-click, or press ⌘, |

Drag the body to turn it. Double-click to face front. Pinch to resize. You can also hold Option and scroll. Drag with three fingers to move the window. You can also hold ⌘ and drag. Double-tap with two fingers to open the body.

On 1.0.6, press the screen firmly to open CarPlay. Hold F5 to talk to Siri on the iPhone.

After you go Home, CarPlay keeps playing. The eyes show what is playing.

SideShow shows the clock, weather, Now Playing, and timers on an old iPad or phone. Scan the code in HomePlay to pair. While the Mac sleeps, that screen keeps the last picture.

## Home Screen in beta 6

The full list is in the [release notes](https://github.com/surfine/HomePlay/releases/tag/v2.0.0-beta.6).

Page two has these apps:

- CarPlay
- Weather
- Timers
- World Clock
- Safari
- Recipes
- Sing
- Games
- Contacts
- Find My

The next page is the App Library. This Home Screen has no Dock.

CarPlay apps from the iPhone are listed under iPhone. Tap one to open it in CarPlay. Hide that group in Settings, Appearance.

- Sing fills the screen with lyrics.
- Games opens games installed on this Mac.
- Contacts places a FaceTime call.
- Home shows a thermostat and cameras.

The thermostat and the cameras need the HomePlay Home helper. This download does not include it. HomePlay explains why, then opens the Home app on the Mac.

Widgets from the Mac desktop can sit on this Home Screen. That includes widgets that came from an iPhone.

Each person has a Home Screen, a Look, playlists, and reminders. Switch from the avatar, or tell ClioTalk "I'm …".

AirDrop to the Mac raises a card. You can send a photo, a web page, or a recipe to the iPhone. While CarPlay is connected, the iPhone blocks AirDrop, so HomePlay sends that item to you in Messages. In Control Center, Receive AirDrop pauses CarPlay. When the file arrives, you are back where you were.

## ClioTalk

Press and hold the eyes, or hold F5, and speak. The Mac transcribes your speech. Only the text goes to the model.

ClioTalk reads a message, a reminder, or an event aloud before it sends the item as you. Say yes, and it sends.

Store an Anthropic or DeepSeek key in the Keychain. You can also run a local model in LM Studio. On macOS 26 or later, you can use the on-device Apple Intelligence model. The cap starts at 5 US dollars a month. At the cap, ClioTalk stops.

Audio stays in memory. An answer is kept only after you tap Keep.

## Who is in front of the Mac

Face recognition stays off until you turn it on. The Mac computes the face. HomePlay stores the feature numbers. It does not store a photo.

Those numbers are general image features. Do not use them as a lock. You can enroll six people. A guest sees the default Home Screen. An unknown face sees that same screen.

## A screen that stays in view

The Mac already has a desktop, windows, notifications, and widgets. HomePlay adds a screen that stays in view. You read a change there. You act there. Then you return to the window you left.

Microsoft Research tried this in 2001. JJ Cadiz, Gina Venolia, Gavin Jancke, and Anoop Gupta built Sideshow. A short summary sits at the edge of the screen. Point at it, and you can act without leaving your work. CSCW 2002 paper: [Designing and Deploying an Information Awareness Interface](https://www.microsoft.com/en-us/research/publication/designing-and-deploying-an-information-awareness-interface-2/).

2001 report: [Sideshow: Providing Peripheral Awareness of Important Information](https://www.microsoft.com/en-us/research/publication/sideshow-providing-peripheral-awareness-of-important-information/).

That Sideshow is a sidebar. HomePlay's SideShow is the paired iPad or phone. The machine on the desk is the screen that stays on.

Apple moved widgets from Dashboard back to the desktop. That path is [A history of widgets](https://homeplay.aaronlau.me/en/history/).

Use Xcode Simulator to test an interface. Use HomePlay when that interface should stay on the desk. A mouse, a trackpad, and a keyboard all work. On a touch Mac, and in Sidecar, a finger can tap, swipe, hold, and pinch. The eyes follow the finger.

## Limits in beta 6

- Liquid Glass, on-device speech, and on-device models need macOS 26 or later.
- Cloud ClioTalk needs your own key.
- FaceTime and Find My finish in the Mac apps with those names. Intercom plays on the Mac, or on an AirPlay speaker.
- YouTube plays audio only. Other video plays picture and sound.
- Reading Messages needs Full Disk Access. Sending uses AppleScript. If delivery is not confirmed, HomePlay tells you and does not retry.
- HomePlay draws its own interface. The CarPlay picture comes from your iPhone.

## Privacy

There is no account. HomePlay does not report how you use it. A feature contacts the network only after you turn that feature on.

- The 1.0 Weather face sends an approximate location to Open-Meteo.
- ClioTalk sends the transcript to the model you selected.
- Lyrics lookup sends the title, the artist, and the duration to LRCLIB. You can turn that lookup off.

HomePlay asks for each permission when the feature needs it.

| Permission | HomePlay asks when | If you refuse |
|---|---|---|
| Camera | You turn on Follow Me or Room Light | The pet still runs |
| Microphone | You start a CarPlay call or ClioTalk | CarPlay picture and touch still work |
| Bluetooth | You pair an iPhone for the first time | USB still works |
| Local Network | HomePlay receives the CarPlay picture | CarPlay cannot connect |
| Location, approximate | The Weather face opens the first time | Weather shows the last city, or nothing |
| Calendar | You turn on the Calendar face | The other faces still work |
| Automation | You turn on Mac Now Playing | The other features still work |
| Full Disk Access | HomePlay reads Messages | Messages stay unread |

The camera stays on this Mac. Frames are not saved and not uploaded. For wireless CarPlay, type the Wi-Fi name and password once in the menu. HomePlay stores them in a local file, mode 0600. It does not read them from the system Keychain. The ClioTalk key is the key you paste in. That key is stored in the Keychain.

## Build 1.0 from source

This repository builds 1.0: the desk pet and the CarPlay receiver. That build matches 1.0.6. Download the beta for the 2.0 app. The 2.0 source is not in this repository.

You need macOS 14 or later, and the Swift 6 toolchain. This source does not include Apple's HomeView USDZ. Put `apple-homeview.usdz` in `Sources/homeplay-pet/Resources/`. Without that file, the body does not load. The signed app already includes it.

The build links libopus and libspeexdsp. Those libraries decode CarPlay phone and Siri audio, and they cancel echo on the uplink. Install them with `brew install opus speexdsp`. `HOMEPLAY_OPUS_LIB` and `HOMEPLAY_SPEEX_LIB` can point at your own static libraries.

```sh
swift build -c release
B=.build/release

$B/homeplay-receiver --source auto --ssid '<Wi-Fi name>' --port 8788
$B/homeplay-pet --endpoint ws://127.0.0.1:8788

$B/session-tests && $B/iap2-offline-tests
```

CarPlay from a source build needs `identity.pk8` and `certificate.p7b`. Pass them with `--identity-dir <dir>`, or set `HOMEPLAY_IDENTITY_DIR`. The pet alone does not need an identity. `--source window` and `--source h264` do not need one either. The tools do not print or upload the identity.

| Target | What it builds |
|---|---|
| `homeplay-pet` | The 3D pet. RealityKit loads the Apple USDZ. The screen shows the receiver, and touch goes back. |
| `homeplay-receiver` | The receiver: `auto`, `wireless`, `usb`, `window`, `h264`. `auto` tries USB, then wireless. |
| `homeplay-verify` | Connects as a client and writes one frame to PNG. |
| `session-tests`, `iap2-offline-tests` | Offline tests for the session and for iAP2. |

Pass `--style` and `--face` to `homeplay-pet`. The eyes have ten expressions. Each expression has its own silhouette.

`--style` accepts:

- Island
- Photos
- Modular
- Typograph
- Flow
- Weather
- Calendar
- Days Together
- Black
- System 6

The signed app includes a public experimental accessory identity. CarPlay works after you install that app. This source snapshot does not include the identity. If you build CarPlay yourself, bring your own `identity.pk8` and `certificate.p7b`. You are responsible for their source and for whether you may use them.

| Document | What it covers |
|---|---|
| [Wireless pairing](docs/wireless.md) | The iAP2 handshake, the Wi-Fi credential, and what to check when pairing fails |
| [Performance](docs/performance.md) | The render loop, idle behavior, and power measurements |
| [Room light](docs/room-light.md) | The optional light estimate from the camera |
| [HomeView study](docs/homeview-study.md) | Proportions, and the structure of the official USDZ |
| [CarPlay notes](docs/carplay-best-practices.md) | How the receiver behaves, including edge cases |

[`docs/evidence/`](docs/evidence/) and [`docs/design-drafts/`](docs/design-drafts/) are earlier studies. They are not shots of the current app.

## License

GPL-3.0-or-later. See [`LICENSE`](LICENSE). The CarPlay session control was written again in Swift, following what MacPlay and LIVI do. Credits are in [`NOTICE`](NOTICE).

HomePlay is a personal project. It is not affiliated with, endorsed by, or certified by Apple Inc. CarPlay and HomeView are trademarks of Apple Inc.

Each publish of this repository is one snapshot commit. [Open an issue](https://github.com/surfine/HomePlay/issues) with the macOS version, the HomePlay version, and the steps that failed.
