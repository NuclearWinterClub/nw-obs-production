# Macro Install Guide — Streaming Computer

## Prerequisites

- OBS Studio 32.x with Advanced Scene Switcher (ASS) 1.33.1+
- obs-plugin-countdown installed (for Doomsday Timer)
- The scene collection `_Nuclear_Winter_Stable_interface_with_MUTEX_and_Webhooks_` imported

---

## Step 1 — Copy HTML Files

Copy both files from `html/` to the path OBS expects:

| File | Destination on streaming computer |
|---|---|
| `nw-countdown.html` | `~/Nuclear Winter Resources/Media/nw-countdown.html` |
| `NW-Signal-Recovery.html` | `~/Nuclear Winter Resources/Media/NW-Signal-Recovery.html` |

> If you use a different path, update the browser source URL in OBS for `SG2 - Countdown` and `SG4 - Recovery` after importing.

---

## Step 2 — Build the NW-Nuke-Overlay Architecture in OBS

The Nuke Strike macro controls groups **inside a dedicated overlay scene** that sits on top of all destination scenes. This must exist before importing the macro.

### 2a. Create scene groups

In the scene `NW - Nuke Overlay`, create these four groups (in this order, bottom to top in the source list):

| Group name | Contents |
|---|---|
| `SG1 - Alert` | "INBOUND NUCLEAR MISSILE" text + Doomsday Timer browser source |
| `SG2 - Countdown` | Browser source pointing to `nw-countdown.html` |
| `SG3 - Strike` | `(`) Nuclear Bomb` media source + any strike text |
| `SG4 - Recovery` | Browser source pointing to `NW-Signal-Recovery.html` |

Set all four groups to **hidden** (eye icon off) as their default state.

### 2b. Add overlay to destination scenes

Add `NW - Nuke Overlay` as a source (nested scene) to each of these scenes, and set it **hidden** by default:

- `NW - MAIN`
- `NW - Front Room`
- `NW - Back Room`

---

## Step 3 — Set Up Doomsday Timer Hotkeys in OBS

In OBS: **Settings → Hotkeys** — find the Ashmanix Countdown Timer entries and assign:

| Hotkey name | Key binding |
|---|---|
| `Ashmanix_Countdown_Timer_Set` | Option+R (Alt+R) |
| `Ashmanix_Countdown_Timer_Start` | Option+T (Alt+T) |

> These hotkeys get stripped from the macro on every OBS restart and must be re-assigned manually each session in the ASS macro editor after loading.

---

## Step 4 — Import Macros into ASS

1. In OBS: **Tools → Advanced Scene Switcher → Macros tab**
2. Click the **import** button (folder icon at the bottom of the macro list)
3. Import `NW_-_Nuke_Strike_Sequence.json`
4. Import `ZowieBox_Audio_Watchdog_-_Front_Room.json`

### After importing NW - Nuke Strike Sequence

Open the macro and manually re-assign hotkey actions:
- Action 8 (HOTKEY): assign **Option+R** — resets Doomsday Timer to 30s
- Action 11 (HOTKEY): assign **Option+T** — starts Doomsday Timer countdown

---

## Macro Reference

### NW - Nuke Strike Sequence (27 actions)

Triggered manually. Sequence:

| Phase | What happens | Duration |
|---|---|---|
| Reset | All SGs hidden, overlay shown in all rooms | instant |
| SG1 Alert | "INBOUND NUCLEAR MISSILE" + Doomsday Timer counting from 30s | 19s |
| SG2 Countdown | HTML 10→0 countdown | 10s |
| SG3 Strike | Nuclear bomb video (hard cut in) | 20s |
| SG4 Recovery | Signal recovery HTML animation | 7s |
| Cleanup | SG4 hidden, overlay fades out of all rooms | 2s fade |

**Total runtime: ~58 seconds**

### ZowieBox Audio Watchdog — Front Room (3 actions)

Condition: audio silent for 6+ seconds **while streaming is active**
Action: toggles `Front Video` source in `NW - Front Room` (hide → 2s wait → show) to kick the ZowieBox capture device.
