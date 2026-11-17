# LinkWave

LinkWave is a native iPhone app for monitoring Huawei fibre ONTs, including the OptiXstar HG8145X6-10 and HG8145V5. It connects to your router over your local Wi-Fi network.

## Download

**[Download the latest LinkWave IPA](https://github.com/moneyray284-art/fibre-monitor/releases/latest/download/LinkWave-v2.3.0.ipa)**

The IPA is unsigned. Install it with SideStore, AltStore, or Sideloadly; it is not an App Store install. You can download the `.ipa` directly from the GitHub Release without extracting a ZIP.

## Requirements and setup

- iPhone running iOS 16 or later
- A supported Huawei ONT reachable on the same Wi-Fi network
- Local Network access enabled for LinkWave

Open LinkWave, choose **Add Router**, and enter your router credentials. Auto-detection can suggest the gateway and router profile when the iPhone is connected to the router's Wi-Fi. The common gateway addresses are `192.168.100.1` and `192.168.2.1`.

## Features

- **Home:** router connection state, live download and upload rates while LinkWave is open, optical receive power, and an internet speed test.
- **Usage:** household download and upload totals from the router, monthly totals, and a calendar-month history chart.
- **Clients:** connected-device list with online/offline filters, search, device details, and available block/unblock controls.
- **Wi-Fi:** 2.4 GHz and 5 GHz controls, network details, QR sharing, and Wi-Fi credential editing for supported security modes.
- **Router profiles:** store multiple router profiles and switch between them.
- **Appearance:** light, dark, or system theme with selectable accent colors and app icons.

Usage totals come from the router's counters. Live speed readings update while the app is in the foreground. LinkWave does not estimate this iPhone's personal data usage or provide a Home Screen widget in this release.

## Privacy and credentials

Router credentials are stored in the iOS Keychain. Router monitoring uses the local network connection to the selected router. Internet speed tests contact their test servers to measure network performance.

## Release

Current version: **2.3.0 (build 8)**.

Download the IPA from [GitHub Releases](https://github.com/moneyray284-art/fibre-monitor/releases). Source code and the iOS build workflow are in this repository.
