# Battery Monitor

Reads a LiFePO4 battery's BMS over Bluetooth. There are three ways to use it, all in this repo:
a web page, a Mac app and an Android app. All three work without internet, which matters when
the power is out and the router is off too.

- Charge, voltage, current, power, cells and temperatures, updated every 2 seconds.
- Charts: while connected, a reading is recorded every 10 seconds and kept on the device for 30 days. CSV export.
- No data is sent anywhere: your device reads it straight from the battery.

This is an English version of [llllldddddd/battery-monitor](https://github.com/llllldddddd/battery-monitor). See [Credits](#credits).

## Web page

Open https://malrubaei.github.io/battery-monitor/ in a browser that has Web Bluetooth:

- Android, Windows, macOS, Linux: Chrome or Edge.
- iPhone and iPad: Safari has no Web Bluetooth, so use a Bluetooth browser such as Bluefy.

After the first visit the page is saved in the browser and opens without internet.
In Chrome you can install it as an app: menu → "Install app" or "Add to Home screen".
Readings are only recorded while the page is open.

## Mac app

The web page in a native window, with Bluetooth through CoreBluetooth. On a Mac with the Xcode
Command Line Tools (`xcode-select --install`), run from the repo folder:

```
mac/build.sh install
```

"Battery Monitor" appears in Applications (`mac/build.sh` without `install` only builds it into `mac/build/`).
Needs macOS 13 or newer; the app runs on both Apple silicon and Intel.

On the first connection macOS asks for Bluetooth permission. The app remembers the battery and connects
to it on launch. If the connection drops, it keeps reconnecting until the battery is back.
While connected, the Mac doesn't sleep (the screen still turns off as usual).

## Android app

The web page in a WebView, with Bluetooth through the Android BLE API. Needs JDK 17 to 21 and the
Android SDK (installing Android Studio gives you both). From the repo folder:

```
cd android && ./gradlew assembleRelease
```

The APK is `android/app/build/outputs/apk/release/app-release.apk`. It is signed with the debug key,
so it installs directly: copy it to the phone and allow installs from unknown sources.
Needs Android 7 or newer.

Like the page, the app keeps the screen on while connected, because otherwise Android stops it.

## How it works

One interface for everything: `index.html`. Both apps package that same file when they are built,
so a change to the page shows up in the apps after a rebuild.

The apps' web views have no Web Bluetooth, so `app/bridge.js` stands in for `navigator.bluetooth`
and passes the commands to the native side: `mac/main.swift` (CoreBluetooth) and
`android/app/src/main/java/.../MainActivity.java` (Android BLE API).

Protocol: Nations Bluetooth module (service `00002760-08c2-11e1-9073-0e8ac72e1001`), Modbus RTU inside, address 1, function 03.

## Files

| Path | What it is |
| --- | --- |
| `index.html`, `sw.js`, `manifest.webmanifest`, `icon-*.png` | The web page, served by GitHub Pages |
| `app/bridge.js` | Bluetooth bridge used by both apps |
| `mac/` | Mac app: Swift source, build script, Info.plist |
| `android/` | Android app: Gradle project |

## Credits

Original project and all of its code: [llllldddddd/battery-monitor](https://github.com/llllldddddd/battery-monitor),
copied from commit `f1b2f98`. The changes here are the English translation and new app IDs
(`io.github.malrubaei.battery`, `io.github.malrubaei.battery-monitor`), so these builds install alongside the original ones.

The original repo has no license file. The Gradle wrapper in `android/` is Apache-2.0, from the Gradle project.
