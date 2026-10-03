# HotLight

A lightweight native macOS menu bar temperature monitor. The app currently appears as **LightHot** and is version **0.7**.

## Features

- Compact thermometer icon and selected temperature in the menu bar.
- Native menu with five sensor choices and a checkmark for the saved selection.
- Thermal pressure and current fan speeds, updated every two seconds.
- Thermometer color follows macOS thermal pressure: normal system color for Nominal, yellow for Fair, and red for Serious or Critical. Pressure changes update immediately; the menu and tooltip show the exact state.
- Read-only hardware access: no privileged helper, fan control, or network connection.

## Requirements

macOS 13 or later, Apple Silicon, and Xcode to build. Sensor choices have been verified on an M1 Pro MacBook Pro; other models may use different sensor keys.

## Build and run

```sh
sh build.sh
open LightHot.app
```

To install, copy the built `LightHot.app` into Applications. The app does not add itself to login items. Quit using its menu.

## Sensors

| Reading | SMC key candidates |
| --- | --- |
| CPU die hotspot | TCMz |
| CPU performance core 1 | Tp01 |
| GPU (hottest) | Tg05, Tg0C, Tg0d, Tg0D, Tg0e, Tg0G, Tg0H, Tg0j, Tg0K, Tg0k, Tg0L, Tg0m, Tg0n, Tg0O, Tg0P, Tg0U, Tg0V, Tg0X, Tg0Y |
| Memory (hottest) | Tm02, Tm0B |
| Battery | TB0T |

The app reads each row’s SMC key candidates and displays the hottest available temperature for that row. The default CPU hotspot falls back to CPU-related HID sensors when unavailable. Missing readings display Unavailable or an em dash. Fan readings use FNum and each fan’s current-speed key; 0 RPM means stopped.

Apple Silicon exposes thermal pressure rather than the Intel scheduler-limit information. The SMC and HID interfaces used here are not stable public Apple APIs.

## Memory

Version 0.7 measured 15.0 MB physical footprint (15.1 MB peak) after startup on the development Mac. The goal is under 20 MB; this is a measurement, not a guarantee across machines or extended use. RSS includes shared frameworks and is a different metric.

## Diagnostics

```sh
./LightHot.app/Contents/MacOS/LightHot --once
./LightHot.app/Contents/MacOS/LightHot --dump-sensors
./LightHot.app/Contents/MacOS/LightHot --fans
```

`--once` reads the default CPU hotspot independently of the saved menu selection.

## Design and references

The interface uses a native AppKit menu, a template icon at nominal pressure and colored icons at elevated pressure, system text styling, standard selection checkmarks, and Command-Q, following [Apple’s menu bar guidance](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar#Menu-bar-extras).

- [Hot](https://github.com/macmade/Hot) inspired the project.
- SMC protocol declarations derive from [SMCKit](https://github.com/macmade/SMCKit); its MIT copyright and license notice are retained in `SMC-Internal.h`.
- HID reading was informed by [SwiftTempBar](https://github.com/WHYBBE/SwiftTempBar).
- M1 sensor naming references the [Stats sensor map](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift).

Fan control, including Full blast, is not implemented. It requires a separate implementation and testing of automatic-control recovery.
