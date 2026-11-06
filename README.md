# SkyStream

<div align="center">
  <a href="https://github.com/akashdh11/skystream/releases">
    <img src="https://img.shields.io/github/downloads/akashdh11/skystream/total?style=for-the-badge&color=1f6feb" />
  </a>
  <a href="https://github.com/akashdh11/skystream/stargazers">
    <img src="https://img.shields.io/github/stars/akashdh11/skystream?style=for-the-badge&color=f1c40f" />
  </a>
  <a href="https://github.com/akashdh11/skystream/releases">
    <img src="https://img.shields.io/github/v/release/akashdh11/skystream?style=for-the-badge&color=f39c12" />
  </a>
  <a href="https://github.com/akashdh11/skystream/issues">
    <img src="https://img.shields.io/github/issues/akashdh11/skystream?style=for-the-badge&color=e74c3c" />
  </a>
  <a href="https://github.com/akashdh11/skystream/issues?q=is%3Aissue+is%3Aclosed">
    <img src="https://img.shields.io/github/issues-search/akashdh11/skystream?query=is%3Aissue+is%3Aclosed&style=for-the-badge&color=2ecc71" />
  </a>
  <a href="https://github.com/akashdh11/skystream/commits/main">
    <img src="https://img.shields.io/github/last-commit/akashdh11/skystream?style=for-the-badge&color=17a2b8" />
  </a>
</div>



**⚠️ Warning: By default, this app doesn't provide any video sources; you have to install extensions to add functionality to the app.**

**A new, cross-platform media streaming application inspired by CloudStream.**

> **Note**: This project is an independent application built with Flutter. While it supports similar extension formats, it is a simplified, modern re-imagining and is **not** a direct clone or fork of the official client.

**Please don't create illegal extensions or use any that host any copyrighted media.** This project does not condone copyright infringement.

## Community

Join the discussion, get help, or find new extensions on our Telegram channel or Discord server:

<a href="https://t.me/+Ez5Vsv2pUUFjZmNl">
  <img src="https://img.shields.io/badge/Telegram-Channel-blue?style=for-the-badge&logo=telegram">
</a>

<br>


<a href="https://discord.gg/73XGA8Mxn9">
  <img src="https://invidget.switchblade.xyz/73XGA8Mxn9">
</a>


## Overview

SkyStream is a modern, media streaming client. It draws inspiration from the versatile architecture of CloudStream but implements a custom, cross-platform JavaScript engine for extensions, enabling support for Android, iOS, and Desktop from a single codebase.

### Built With

![Flutter](https://img.shields.io/badge/Flutter-%2302569B.svg?style=for-the-badge&logo=Flutter&logoColor=white) ![Dart](https://img.shields.io/badge/dart-%230175C2.svg?style=for-the-badge&logo=dart&logoColor=white) ![Riverpod](https://img.shields.io/badge/Riverpod-%232D3748.svg?style=for-the-badge&logo=riverpod&logoColor=white) ![Hive](https://img.shields.io/badge/Hive-%23DE3027.svg?style=for-the-badge&logo=hive&logoColor=white)

### Screenshots

### 📱 Mobile

<p align="center">
  <img src="screenshots/mobile/home.png" width="360" />
    <img src="screenshots/mobile/discover.png" width="360" />
  <img src="screenshots/mobile/details.png" width="360" />
  <img src="screenshots/mobile/settings.png" width="360" />
</p>

### 📺 Large screen

<p align="center">
  <img src="screenshots/tv/details_1.png" width="720" />
  <img src="screenshots/tv/details_2.png" width="720" />
</p>

## Supported Platforms

| Platform       |         Support          |
|:---------------|:------------------------:|
| **Android**    |            ✅             |
| **Android TV** |            ✅             |
| **iOS**        | ✅ (Sideloading required) |
| **Windows**    |            ✅             |
| **macOS**      |            ✅             |
| **Linux**      |            ✅             |

## ✨ Features

💡 **SkyStream** is designed as a **scalable, plugin-driven, cross-platform streaming platform**—delivering flexibility, performance, and a seamless viewing experience across all devices.

### 🔎 Powerful Search & Discovery
- 🔍 **Plugin-wise Search** – Search within specific providers for more accurate results  
- 💡 **Smart Search Suggestions** – Get real-time suggestions while typing  
- 🌐 **Advanced Discovery (TMDB Integration)** – Explore trending, popular, and filtered content  
- 🎯 **Custom Home Experience** – Set Explore as your default landing screen  
- 🌍 **Multi-language Filtering** – Discover content across 40+ languages

### 🎬 Advanced Streaming Experience
- 📺 **Live Streaming Support** – Watch live content with improved reliability  
- ▶️ **Resume Playback** – Continue watching from where you left off  
- ⏩ **Playback Speed Control** – Adjust speed to your preference  
- 🎚️ **Default Quality Selection** – Set preferred streaming quality  
- 📑 **Episode Overlay** – Browse and switch episodes inside the player  
- 🔍 **Detailed Loading Insights** – View source details while content loads

### 🔗 Integrations & Tracking
- 🔄 **Multi-Tracker Sync** – Keep your watch list and progress synchronized across **Trakt**, **Simkl**, **MyAnimeList (MAL)**, and **AniList**
- ⏭️ **Smart Skip (Intro/Outro)** – Seamlessly skip intro and outro sequences using **IntroDB** and **Anime Skip** integration

### 🧩 Extensions: SkyStream, CloudStream, Nuvio & Stremio
SkyStream plays from four kinds of extensions, side by side. Install and manage each of them in **Settings → Extensions**.
- 🔌 **SkyStream plugins** – SkyStream's own JavaScript providers. One plugin can carry several providers, follow a site to its new domain, and log what it does in the app's developer tools
- ☁️ **CloudStream extensions** – Run CloudStream `.cs3` extensions on Android, iOS, macOS, Windows and Linux. Add a repository by its URL, a `cloudstreamrepo://` link or a shortcode
- 🕸️ **Nuvio plugins** – Nuvio's scrapers find streams for the movies and shows you open from TMDB, listed together so you pick one
- 🧱 **Stremio add-ons** – Install any add-on by its manifest URL or from the community directory
- 🔎 **One search for all of them** – A single search bar covers SkyStream, CloudStream, Stremio and Nuvio, with a section per source and every result tagged with where it came from

### 💬 Subtitles & Content Flexibility
- 🌍 **External Subtitles Support** – Integrated with:
  - OpenSubtitles  
  - SubDL  
  - Subsource  
- 📝 **Subtitle Styling** – Customizable font size and colors

### 📥 Offline & External Playback
- ⬇️ **Download Content** – Watch offline anytime  
- 🎥 **External Player Support** – Play content in your preferred media player

### 📺 Cross-Platform Support
- 📱 Android & iOS  
- 💻 macOS, Windows & Linux  
- 📺 Android TV + tvOS (Apple TV) support

### ⚡ Performance & Reliability
- 🚀 **Optimized Performance** – Faster load times and smoother UI  
- 🧠 **New JavaScript Engine (`quick_js_ng`)** – Better execution and compatibility  
- 🌐 **DNS over HTTPS** – Bypass ISP restrictions for improved access  
- 📉 **Reduced App Size** – Lightweight and efficient  
- 🔧 **Stability Improvements** – Enhanced reliability across all platforms

### 🎨 Modern UI/UX
- 🎨 **Clean & Modern Interface** – Redesigned Home and Details screens  
- 🧭 **Improved Navigation** – Explore-based content discovery  
- 🌗 **Theme Improvements** – Better light mode and UI consistency  
- 🖥️ **Enhanced Desktop Experience** – Improved windowed mode support

### 🌍 Global Accessibility
- 🌐 **40+ Language Support** – Fully localized experience  
- 🎯 **Region-aware Discovery** – Content tailored to global audiences

## 📥 Installation

Download the latest version from the **[Releases Page](https://github.com/akashdh11/skystream/releases/latest)**.

### 🤖 Android / Android TV
1. Download the `skystream-android-arm64-v8a-vX.Y.Z.apk` (recommended for most modern phones) or `skystream-android-armeabi-v7a-vX.Y.Z.apk` (for TV) from Releases.
2. Open the file and tap **Install**.
   - *Note: You may need to allow "Install from Unknown Sources" in your browser settings.*
3. Open SkyStream and install extensions via **Settings > Extensions**.

### 🍏 iOS (Sideloading)
SkyStream is not on the App Store. You must **sideload** it using a computer.

**Requirements:**
- A Computer (Windows or macOS)
- [Impactor](https://impactor.khcrysalis.dev/) (Free and OpenSource) or [Sideloadly](https://sideloadly.io/) (Free)
- [iTunes](https://support.apple.com/en-us/106372) (if on Windows)

**Guide**
- [Impactor Guide](https://impactor.khcrysalis.dev/docs/getting-started/installing/)
- [Sideloadly Video Guide](https://www.youtube.com/watch?v=vqTsavQc3lQ)

**Steps:**
1. Download `skystream-ios-unsigned-vX.Y.Z.ipa` from the [Releases Page](https://github.com/akashdh11/skystream/releases/latest).
2. Open **Impactor** or **Sideloadly** on your computer.
3. Connect your iPhone/iPad via USB.
4. Drag the `.ipa` file into the Sideloadly window.
5. Enter your **Apple ID** in the configured field.
6. Click **Start**.
7. Once finished, the app will appear on your home screen.
8. On your device, go to **Settings > General > VPN & Device Management**, tap your email, and select **Trust**.
9. Set up Wi-Fi sync to automatically refresh your apps in the background

### 💻 Windows / macOS
1. Download the file for your system from Releases:
   - **Windows (x64):** the `SkyStream-Windows-x64-Setup` installer (`.exe`), or `skystream-windows-x64-vX.Y.Z.zip` to run without installing.
   - **macOS:** `skystream-macos-arm64-vX.Y.Z.dmg` for Apple silicon, `skystream-macos-x64-vX.Y.Z.dmg` for Intel (a `.zip` of each is there too).
2. Install the app.
3. Run it from your app launcher.
   - *macOS Note: If you see an “Unidentified Developer” warning, go to Settings → Privacy & Security and click Open Anyway to allow the app (one-time step).*

### 🐧 Linux
Each release has three Linux downloads, for **x64** and **arm64** (`skystream-linux-x64-…`, `skystream-linux-arm64-…`). They need glibc 2.35 or newer: Ubuntu 22.04, Debian 12, Fedora 36 or later.

| File | For |
|:-----|:----|
| `skystream-linux-<arch>-vX.Y.Z.deb` | Debian, Ubuntu and their derivatives. Installs everything SkyStream needs. |
| `skystream-linux-<arch>-vX.Y.Z.AppImage` | Any distribution. Runs without installing. |
| `skystream-linux-<arch>-vX.Y.Z.tar.gz` | Any distribution, unpacked wherever you like. |

**`.deb`** – apt installs SkyStream with VLC, WebKitGTK and the other libraries it needs:
```bash
sudo apt install ./skystream-linux-x64-vX.Y.Z.deb
```

**AppImage** – make it executable, then run it:
```bash
chmod +x skystream-linux-x64-vX.Y.Z.AppImage
./skystream-linux-x64-vX.Y.Z.AppImage
```
*On a system without FUSE (some containers), run it with `--appimage-extract-and-run`.*

**`.tar.gz`** – unpack it and run `skystream` from the folder:
```bash
mkdir -p ~/skystream
tar -xzf skystream-linux-x64-vX.Y.Z.tar.gz -C ~/skystream
~/skystream/skystream
```

The AppImage and the `.tar.gz` use VLC, WebKitGTK 4.1, GTK 3 and libsecret from your system, and the AppImage tells you if one is missing. On Debian or Ubuntu:
```bash
sudo apt install libvlc5 vlc-plugin-base libwebkit2gtk-4.1-0 libgtk-3-0 libsecret-1-0
```

## 🛠️ Build from Source

To set up the development environment, clone the repository and run the setup commands. Detailed instructions for environment configuration, platform-specific builds, and project architecture can be found in our contributor guide:

👉 **[CONTRIBUTING.md](docs/CONTRIBUTING.md)**

### Quick Start
```bash
git clone https://github.com/akashdh11/skystream.git
cd skystream
flutter pub get
flutter gen-l10n
dart run build_runner build --delete-conflicting-outputs
flutter run
```

Desktop builds need a JDK 17 or newer: CloudStream extensions run on Java on macOS, Windows and Linux (see [CONTRIBUTING.md](docs/CONTRIBUTING.md)).

**Pigeon** – the challenge browser's platform bindings (`packages/challenge_browser`) are generated by Pigeon and committed, so a fresh clone builds without running it. Only after changing `packages/challenge_browser/pigeons/messages.dart`, regenerate its Dart, Kotlin, Swift, C++ and GObject files together:
```bash
cd packages/challenge_browser
dart run pigeon --input pigeons/messages.dart
```

## 🤝 Contributing

We welcome contributions of all kinds! Whether you are fixing a bug, adding a feature, or helping with translations, your help is appreciated.

- **Found a bug?** Report it on our **[GitHub Issues](https://github.com/akashdh11/skystream/issues)** page.
- **Want to translate?** See our **[Translation Guide](docs/CONTRIBUTING_TRANSLATIONS.md)**.
- **Want to build a plugin?** Check the **[Extension Guide](https://github.com/akashdh11/skystream-tools/blob/main/DEVELOPER.md)**.
- **Need help?** Join the community on **[Discord](https://discord.gg/73XGA8Mxn9)** or **[Telegram](https://t.me/+Ez5Vsv2pUUFjZmNl)**.

---

## FAQ

<details>
<summary><b>How do I install extensions?</b></summary>
SkyStream uses `.sky` or `.js` extension files. You can install them by navigating to <b>Settings > Extensions > Add Repository</b> and entering a repository URL (e.g., using a shortcode).
</details>

<details>
<summary><b>Where is the media stored?</b></summary>
SkyStream is a streaming client and does not host any content. All media is streamed directly from the third-party extensions you install.
</details>


## Star History

## Star History

<a href="https://star-history.dera.page/#akashdh11/skystream&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://star-history.dera.page/svg?repos=akashdh11/skystream&type=date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://star-history.dera.page/svg?repos=akashdh11/skystream&type=Date" />
   <img alt="Star History Chart" src="https://star-history.dera.page/svg?repos=akashdh11/skystream&type=Date" />
 </picture>
</a>


## Contributors

<a href="https://github.com/akashdh11/skystream/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=akashdh11/skystream" />
</a>

## License

SkyStream is licensed under the [GNU General Public License v3.0](LICENSE) (GPL-3.0-only). 