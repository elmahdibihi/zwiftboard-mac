<div align="center">

# ZwiftBoard for macOS

**A lightweight, native macOS menu bar bridge for Zwift Click (V1 & V2) controllers on MyWhoosh.**

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B%20(Apple%20Silicon)-0a84ff?style=flat-square)](https://github.com/elmahdibihi/zwiftboard-mac/releases)
[![Swift](https://img.shields.io/badge/Swift-6.0-f05138?style=flat-square)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-22c55e?style=flat-square)](LICENSE)
[![Release](https://img.shields.io/github/v/release/elmahdibihi/zwiftboard-mac?style=flat-square)](https://github.com/elmahdibihi/zwiftboard-mac/releases/latest)

*Unofficial macOS app inspired by [thomaschampagne/zwiftboard](https://github.com/thomaschampagne/zwiftboard).*

<br/>

<img src="screenshots/menubar.png" alt="ZwiftBoard macOS Menu Bar" width="820"/>

</div>

---

## Why ZwiftBoard for macOS?

MyWhoosh supports virtual shifting (**MyShift**) via keyboard shortcuts (`I` / `K`), while Zwift Click controllers speak a proprietary Bluetooth Low Energy protocol (`FC82` / `00000001-...`). **ZwiftBoard** sits quietly in your macOS menu bar and translates every Click press into clean, low-latency keystrokes.

- **Native `CoreBluetooth` + `AppKit`** — zero Electron, Python, or background runtime bloat (`~134 KB` zipped)
- **Click V1 & V2 Ready** — supports both `FC82` and legacy Zwift GATT services, with mirrored Left/Right pod deduplication (`HoldTracker`)
- **Sleep-Proof & Battery-Safe** — keeps pods awake with `RideOn` + `0x18` while riding, and automatically disconnects all pods and quits when MyWhoosh closes so your Click batteries don't drain between rides
- **MyWhoosh Integration** — one-click **Launch / Focus MyWhoosh** and **Auto-Focus on Click**
- **Single & Double Modes** — use the Right Pod alone without any Zwift login, or both pods together (with optional Zwift `d-lock` sign-in if the Left Pod locks)

---

## Default MyWhoosh Keymap

| Mode | Controller Button | Key Sent | MyWhoosh Action |
| :--- | :--- | :--- | :--- |
| **Double** | `PLUS` | `K` *(swappable)* | Shift Up (Harder) |
| **Double** | `MIN` | `I` *(swappable)* | Shift Down (Easier) |
| **Double** | `LEFT` / `RIGHT` / `UP` / `DOWN` | Arrow Keys | Steer / Navigate |
| **Double** | `Y` / `B` | `U` / `Return` | U-Turn / Confirm |
| **Single** | `PLUS` | `I` *(swappable)* | Shift Down (Easier) |
| **Single** | `B` | `K` *(swappable)* | Shift Up (Harder) |
| **Single** | `A` / `Z` / `Y` | `→` / `←` / `U` | Steer / U-Turn |

---

## Quick Install

1. Download **`ZwiftBoard-macOS.zip`** from [**Releases**](https://github.com/elmahdibihi/zwiftboard-mac/releases/latest).
2. Unzip and move **`ZwiftBoard.app`** into `/Applications`.
3. Open `ZwiftBoard.app` *(if macOS Gatekeeper warns on first launch, right-click → **Open**, or run `xattr -cr /Applications/ZwiftBoard.app`)*.
4. Allow **Bluetooth** when prompted, then click the **bicycle icon** in the menu bar → **⚠️ Grant Accessibility Permission** (required by macOS to send keystrokes to MyWhoosh).

### MyWhoosh Checklist
- Pair your smart trainer under **Power & Controllable / Resistance** in MyWhoosh.
- Start a **Free Ride** (virtual gears are disabled in ERG-mode workouts).
- Use **Single (Right Pod)** mode for zero-login shifting, or **Double (Both Pods)** mode (sign in via **Sign In to Zwift** in the menu if your Left Pod shows `(Locked)`).

---

## Build from Source

Requires **macOS 13+** and **Swift 6+** (Xcode Command Line Tools):

```bash
git clone https://github.com/elmahdibihi/zwiftboard-mac.git
cd zwiftboard-mac
./build.sh
```

This compiles the release binary, packages `dist/ZwiftBoard.app`, ad-hoc signs it, and outputs `dist/ZwiftBoard-macOS.zip`.

---

## License

MIT — see [LICENSE](LICENSE).
