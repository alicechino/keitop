# keitop

keitop is a native macOS system monitor built with SwiftUI and Swift Charts. The app targets macOS 14 and later.

## Features

- Overview cards for CPU and GPU load, power, temperatures, memory, network throughput, disk read/write throughput, battery charge, and thermal state
- Per-core CPU usage and CPU model
- Process list with full application names and icons, name/PID search, and ascending/descending CPU or memory sorting
- Process termination with a confirmation step: send `SIGTERM` first, then ask again before sending `SIGKILL` if the process is still running after three seconds
- Process termination is limited to processes owned by the current user; keitop and selected system processes are protected
- Fan speed display, saved metric snapshots, and a movable OSD window
- Dark and light appearance modes

## Sensor backend

keitop reads Apple Silicon sensor data from `mactop` in headless JSON mode. It can fall back to `macmon`. Install either tool with Homebrew:

```sh
brew install mactop
```

or:

```sh
brew install macmon
```

The app does not write to the SMC or change fan settings. Some sensor readings depend on undocumented hardware interfaces and may vary by Mac model or macOS version. If no sensor backend is available, CPU load, memory, and macOS thermal state remain available while unsupported sensor values are shown as unavailable.

## Build

Open `MacStatus.xcodeproj` in Xcode and choose the `keitop` scheme, or build from Terminal:

```sh
xcodebuild -project MacStatus.xcodeproj -scheme keitop -configuration Release build
```

The Swift package can also be built with:

```sh
swift build
```

## Release

The Xcode project produces a universal macOS app for Apple Silicon and Intel. Release signing, notarization, and distribution are not configured in this source repository.

## License

The source code is distributed under the MIT License. The illustration bundled in `Assets.xcassets/AppIcon.appiconset` is excluded from that license and remains the property of its respective rights holder.

## UI Preview

!(./1.png)
!(./2.png)
!(./3.png)
!(./4.png)
!(./5.png)
