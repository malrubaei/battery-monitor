# Battery Monitor

English translation of [llllldddddd/battery-monitor](https://github.com/llllldddddd/battery-monitor): the web page plus its Mac and Android apps, with the apps' text translated to English. All credit for the original code goes to its author.

LiFePO4 battery readings over Bluetooth: a web page, a Mac app and an Android app.
All three work without internet — which matters when the power is out and the router is off too.

- Charge, voltage, current, power, cells, temperatures — updated every 2 seconds.
- Charts: while connected, readings are recorded every 10 seconds and kept on the device for 30 days. CSV export.
- No data is sent anywhere: the device reads it directly from the battery.

## Web page

https://malrubaei.github.io/battery-monitor/ — Chrome on Android or a computer.
After the first visit the page is saved in the browser and opens without internet.
In Chrome you can install it as an app: menu → "Install app" / "Add to Home screen".

## Mac

```
mac/build.sh install
```

Only the Xcode Command Line Tools are needed. The "Battery Monitor" app appears in Applications.
On first connection macOS asks for Bluetooth permission. It remembers the battery and connects to it on launch;
if the connection drops, it keeps reconnecting until the battery is back. While connected, the Mac doesn't sleep (the screen turns off as usual).

## Android

```
cd android && ./gradlew assembleRelease
```

Output: `android/app/build/outputs/apk/release/app-release.apk` (signed with the debug key, installs directly;
you need to allow installs from unknown sources). Android 7 or newer. Requires JDK 17–21.
Like the page, it keeps the screen on while connected, otherwise Android stops the app.

## How it works

One interface for everything: `index.html`. The apps have no Web Bluetooth, so `app/bridge.js` replaces
`navigator.bluetooth` and passes commands to the native side: `mac/main.swift` (CoreBluetooth) and
`android/.../MainActivity.java` (Android BLE API).

Protocol: Nations Bluetooth module (service `00002760-08c2-11e1-9073-0e8ac72e1001`), Modbus RTU inside, address 1, function 03.

## Credits

Original project: [llllldddddd/battery-monitor](https://github.com/llllldddddd/battery-monitor), copied from commit `f1b2f98`.
The changes here are the English translation and new app IDs (`io.github.malrubaei.battery`), so these builds install alongside the original ones.
The original repo has no license file. The Gradle wrapper in `android/` is Apache-2.0, from the Gradle project.
