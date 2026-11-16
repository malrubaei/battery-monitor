# Battery – native iOS app

A SwiftUI version of the web page, for iPhone. It talks to the BMS directly
with CoreBluetooth and, unlike the page in Bluefy, **keeps recording while the
phone is locked or the app is in the background**.

## What it does

- **Now**: charge, mode, voltage, current, power, remaining capacity, time to
  full/empty, cycles, health, each cell with min/max/difference, temperatures.
- **Charts**: charge, power, voltage, highest/lowest cell and temperature for
  1 h, 6 h, 24 h, 7 d or everything, with a touch crosshair. Export as CSV
  (share sheet) or clear the history.
- Readings are polled every 2 s on screen (10 s in the background) and stored
  every 10 s in a SQLite file on the phone, kept for 30 days.
- The app remembers the battery and reconnects on its own after a power cut,
  also in the background, and after iOS relaunches it (state restoration).
- “Show example” shows made-up data, as on the page.

The protocol is the same as the page: Nations BLE UART module
(service `00002760-08c2-11e1-9073-0e8ac72e1001`) with Modbus RTU, slave 1,
function 03 inside. See `BatteryMonitor/BMSProtocol.swift`.

## Build and install with a free Apple ID

1. Install Xcode (26.x on an Intel Mac, from developer.apple.com/download/all; the App Store Xcode 27 needs Apple silicon) and sign in under
   Xcode → Settings → Accounts with your Apple ID.
2. Open `ios/BatteryMonitor.xcodeproj`.
3. Select the **BatteryMonitor** target → Signing & Capabilities → Team: your
   “(Personal Team)”. If the bundle id is taken, change it to something unique,
   e.g. `com.yourname.batterymonitor`.
4. Plug in the iPhone, unlock it and tap **Trust**. On the iPhone, turn on
   Settings → Privacy & Security → Developer Mode (it restarts).
5. Choose the iPhone as the run destination and press Run (⌘R).
6. The first time, iOS blocks the app: on the iPhone go to Settings → General →
   VPN & Device Management → your Apple ID → Trust.

With a free account the app stops opening after **7 days**; run it from Xcode
again to renew it. A paid developer account (99 USD/year) gives one year.

## Background recording notes

iOS keeps a Bluetooth connection open for apps with the `bluetooth-central`
background mode and wakes the app when data arrives. The app keeps its poll
chain going between those wakes with short background tasks. If you close the
app by swiping it away in the app switcher, iOS stops it and recording ends
until you open it again. Low Power Mode can also make iOS stricter.
