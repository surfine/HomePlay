<div align="center">
  <img src="assets/github/hero-v2.gif" alt="HomePlay: an eye close-up pulls back into a tiny 3D HomeView on a Mac desktop" width="720">
  <h1>HomePlay</h1>
  <p><strong>It looks at you, and brings CarPlay to your Mac.</strong></p>
  <p>HomeView, made into a desk pet for your Mac: try the HomeView software before the hardware ships.</p>
  <p><a href="README.md">简体中文</a> · <a href="https://homeplay.aaronlau.me/en/">Website</a></p>
  <p>
    <a href="https://github.com/surfine/HomePlay/releases/latest"><img src="https://img.shields.io/github/v/release/surfine/HomePlay?label=download&style=flat-square" alt="Latest release"></a>
    <img src="https://img.shields.io/badge/macOS-14%2B-15181c?style=flat-square" alt="macOS 14+">
    <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-15181c?style=flat-square" alt="Apple Silicon">
    <img src="https://img.shields.io/badge/Swift-RealityKit-2a63d4?style=flat-square" alt="Swift + RealityKit">
    <img src="https://img.shields.io/badge/license-GPL--3.0--or--later-2a63d4?style=flat-square" alt="GPL-3.0-or-later">
  </p>
</div>

> Experimental personal project. Not affiliated with, endorsed by, or certified by Apple. CarPlay and HomeView are trademarks of Apple Inc. Use at your own risk.

## ⭐️ Features

- **Plug in once, then wireless.** Pairing works like a Magic accessory: connect the iPhone to the Mac with a cable once, it switches to wireless when pairing is done, and unplugging later doesn't drop CarPlay.
- **Ten expressions, many faces.** Ten expressions and a set of faces (Liquid Glass numerals, Flow bubbles, Modular, Analog, Bedside…) to add a little life to ordinary days, and help you feel a bit more calm and at ease.
- **Press a little harder, and it's CarPlay.** A continuous CarPlay experience on your Mac desktop. Unlike iPhone Mirroring, you can reach your iPhone's Siri through the Mac: hold F5 and just talk, completely hands-free, so work stays focused.
- **More than CarPlay.** A Pomodoro timer, battery and Now Playing widgets, and an always-on-top window: like the iTunes MiniPlayer, but playing your iPhone's library, more flexible than AirPlay to Mac (F7–F9 skip tracks).

<img src="assets/github/grid-v2.webp" alt="HomePlay front view, back view, real CarPlay music screen, and exploded anatomy" width="100%">

| Faces | Ten expressions |
|:---:|:---:|
| <img src="assets/github/styles-v2.webp" alt="Island, Flow, Modular, Analog, Pocket and Bedside faces" width="100%"> | <img src="assets/github/faces-v2.webp" alt="Ten expressions made from the same pair of eyes" width="100%"> |

<img src="assets/github/finishes-v2.webp" alt="G4 white, silver, starlight, rose, and space gray finishes" width="100%">

## 💡 Before you start

- **Tested iPhones:** so far only an iPhone SE (1st generation, Lightning) on iOS 15 and an iPhone 18 Pro (USB-C) on iOS 27. Reports on other models are welcome.
- **Gestures:** pinch to zoom, two-finger swipe to rotate, three-finger drag to move.
- **It follows you:** the context menu has a DockKit-style follow mode, like the iMac G4 ad, and can match the room's light.

## 🧑🏻‍💻 From the developer

> 👀 is one of my favorite emoji, for excitement and anticipation. Donald Duck is one of my favorite cartoon characters too: big lively eyes, a bit goofy, adorable.
>
> I believe that in the age of AI, staying curious, freeing your imagination, being creative, keeping your judgment and learning to work together matter more than ever. I hope this little desk pet brings you some fun.

## Install

**Requirements:** macOS 14 or later, Apple Silicon.

[**Download HomePlay-macOS-arm64.zip**](https://github.com/surfine/HomePlay/releases/latest/download/HomePlay-macOS-arm64.zip), then:

1. Unzip and drag `HomePlay.app` into Applications.
2. Open it. The desk pet appears with its clock and eyes. No account, profile, or setup.
3. For CarPlay, connect an iPhone over USB once and accept Trust and Pair on the iPhone.
4. Press firmly on the pet to enter CarPlay. Unplugging switches to wireless after the first pairing.

The release is Developer ID signed and notarized by Apple, so Gatekeeper opens it after unzipping. The matching checksum is [`HomePlay-macOS-arm64.zip.sha256`](https://github.com/surfine/HomePlay/releases/latest/download/HomePlay-macOS-arm64.zip.sha256). Verify with `shasum -a 256 -c HomePlay-macOS-arm64.zip.sha256`.

## What's new in 0.6.1

- **The system's own Liquid Glass.** The big numerals are drawn by the same engine macOS 27 uses for Liquid Glass: the lensing, the thickness and the rim light all match the system. On Flow, the rims follow you.
- **Font & Color.** Like the iOS 27 Lock Screen: six system clock fonts with a weight slider, swatches (or match the wallpaper) with a tone slider, Glass or Solid. Right-click › Faces › Font & Color, or Settings › Appearance.
- **The system clock numerals.** The same digits as the iOS Lock Screen, which grow taller without distorting; the hairline inside the "9" is gone.
- **Lighter on power.** Idle CPU down from about 9% to about 5%.

[Full release notes](https://github.com/surfine/HomePlay/releases/tag/v0.6.1)

## Technical details

- **Real CarPlay**: wireless (Bluetooth iAP2 to Wi-Fi) or wired USB, H.264 and HEVC video, touch sent back to the iPhone, sound through the Mac, and Now Playing in Control Center.
- **Built from the official product**: Apple's HomeView USDZ geometry and materials, five finishes, a back USB-C port, and RealityKit IBL at Quick Look quality.
- **Quiet and power-aware**: idle turns into a static poster and the ARView leaves the window; occlusion and display sleep stop rendering. No notifications, no feedback, no telemetry.
- **Zero setup**: the receiver finds the current Wi-Fi and matches the phone; pairing and unplugging switch automatically. No Keychain access and no admin password.
- **Public-facing**: one instance, VoiceOver labels, English, Simplified Chinese and Traditional Chinese, localized permission strings, GPL source.

## How it works

```mermaid
flowchart LR
  iPhone[iPhone CarPlay] -- "USB / Wi-Fi + iAP2" --> Receiver[homeplay-receiver]
  Receiver -- "WebSocket H.264 / HEVC" --> Pet[homeplay-pet, RealityKit]
  Pet -- "HID touch" --> Receiver
```

## Gestures

<details>
<summary>All gestures</summary>

| Gesture | Result |
|---|---|
| Drag, or two-finger swipe | Turn the body |
| Three-finger drag, or ⌘ drag | Move it (drag the frame while streaming) |
| Pinch, ⌘+, ⌘−, ⌘0 | Zoom (⌘0 resets) |
| Press firmly | Enter or leave CarPlay |
| Long press the screen | Change the face |
| Double-click | Reset the angle |
| Two-finger double tap | Take it apart or put it back |
| ⌘H | Hide the pet (the menu bar icon brings it back) |

</details>

## Privacy and permissions

HomePlay talks to no server. There is no account and no telemetry. Permissions are requested one feature at a time:

| Permission | When it is asked | If denied |
|---|---|---|
| Camera | When Follow Me or Room Light is enabled | The pet works normally |
| Microphone | The first CarPlay call or Siri request | The CarPlay screen and touch still work |
| Bluetooth | The first iPhone pairing | USB still works |
| Local Network | Receiving the CarPlay picture | CarPlay cannot connect |
| Calendar | When the calendar face is enabled | Other faces still work |
| Automation | When Mac Now Playing is enabled | Other features still work |

Camera frames are processed on this Mac, never saved and never uploaded. If wireless CarPlay needs Wi-Fi credentials, the user enters them once in the menu and they are stored in a local 0600 file. The system Keychain is not read.

## Build from source

You need macOS 14 or later and the Swift 6 toolchain.

The public source snapshot does **not** include Apple's HomeView USDZ. Add `apple-homeview.usdz` to `Sources/homeplay-pet/Resources/`, or the pet body will not load. The signed release already includes it.

```sh
swift build -c release
B=.build/release

$B/homeplay-receiver --source auto --ssid '<Wi-Fi name>' --port 8788
$B/homeplay-pet --endpoint ws://127.0.0.1:8788

$B/session-tests && $B/iap2-offline-tests
```

For CarPlay from source, supply `identity.pk8` and `certificate.p7b` with `--identity-dir <dir>` or `HOMEPLAY_IDENTITY_DIR`. Only the pet, or `--source window` / `h264`, does not need an identity. The source does not print or upload identity material.

| Target | What it is |
|---|---|
| `homeplay-pet` | The 3D pet: RealityKit + Apple USDZ, live receiver picture, touch back |
| `homeplay-receiver` | Receiver: `auto` (USB or wireless), `wireless`, `usb`, `window`, `h264` |
| `homeplay-verify` | Acts as a client and decodes one frame to PNG |
| `session-tests` / `iap2-offline-tests` | Offline session and iAP2 tests |

## Docs

| Doc | What is inside |
|---|---|
| [Wireless pairing](docs/wireless.md) | The iAP2 handshake, the optional Wi-Fi credential, and troubleshooting |
| [Performance](docs/performance.md) | The render loop, idle behavior, and power measurements |
| [Room light](docs/room-light.md) | The optional camera-based lighting estimate |
| [HomeView study](docs/homeview-study.md) | Proportions and the official USDZ structure |
| [CarPlay notes](docs/carplay-best-practices.md) | Receiver implementation notes and edge cases |

Historical renders and design drafts live in [`docs/evidence/`](docs/evidence/) and [`docs/design-drafts/`](docs/design-drafts/). They are historical, not current product screenshots.

## Identity (source builds only)

The signed release bundles a public experimental accessory identity, so CarPlay works out of the box and the user does not need to prepare any identity file. The public source snapshot does not include that identity. If you build from source and want CarPlay, provide your own `identity.pk8` and `certificate.p7b`; legality and provenance are your responsibility. The tools never print identity contents.

## Credits and license

GPL-3.0-or-later, see [`LICENSE`](LICENSE). The CarPlay session control plane was reimplemented in Swift after studying MacPlay and LIVI behavior; credits and copyright notices are in [`NOTICE`](NOTICE).

HomePlay is a personal experiment and is not affiliated with Apple Inc. CarPlay and HomeView are trademarks of Apple Inc. and are used here only to describe compatibility.

This repository is a curated snapshot synced from a private development repository, so its history is one sync commit at a time.

## Feedback

Open an [issue](https://github.com/surfine/HomePlay/issues). There is no support SLA, but reproducible reports are read.
