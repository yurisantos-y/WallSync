# Measuring WallSync

Every performance claim WallSync makes can be checked on a real Mac with the
tools below. Nothing here needs a debug build; a Release build signed for
development is the right thing to measure.

## What the app exposes

| Tool | Where | What it tells you |
| --- | --- | --- |
| Unified log | subsystem `com.yurisantos.wallpaper` | Every mode change, with the reason and the trigger |
| Signposts | same subsystem, category `performance` | Duration of reconciles, window-list queries, playback preparation, transcodes, poster generation, and the intervals during which a video is being decoded |
| Diagnostics | Settings › Diagnostics (bottom of the page) | Per display: energy mode, reason, playback state, video source, decoded resolution / fps / codec. **Copy summary** puts a text report on the clipboard |
| MetricKit | log category `metrics` | Daily energy / CPU / hang / crash payloads delivered by the system |

Log categories: `session`, `playback`, `energy`, `import`, `storage`, `metrics`.

Stream the log while you reproduce a scenario:

```bash
log stream --level debug --predicate 'subsystem == "com.yurisantos.wallpaper"'
```

Useful lines:

- `energy`: `display <uuid>: animate -> suspend reason=occluded trigger=occlusion_poll`
- `playback`: `asset <uuid>: decoding started surfaces=3` / `decoding stopped`
- `playback`: `asset <uuid>: prepared=true source=optimized`
- `session`: `reconcile #42 reason=power_changed displays=2 sessions=2`

"Decoding stopped" for every asset is the app's own statement that no frame
is being decoded. Confirm it independently with Instruments (below).

## Instruments

Profile with **Product › Profile** in Xcode, or attach to the running app.

### Energy Log / Power Profiler

Use the *Power Profiler* template (Xcode 26+; the *Energy Log* template on
older versions). Record at least 60 seconds per scenario, on battery,
with nothing else running. Compare the app's CPU and GPU power impact across
scenarios. `sudo powermetrics --samplers tasks,gpu_power -i 5000` gives the
same numbers from the terminal and also shows whether the media engine
(hardware decoder) is busy.

### Time Profiler

Confirms the main thread is idle. Expected while animating: no samples in
WallSync code apart from the occlusion re-evaluation every few seconds
(`WindowListQuery` signposts) and, when one video is mirrored to several
displays, the frame-distribution callback. Expected while suspended: nothing.

### Core Animation

Use the *Core Animation FPS* / *Display* instruments (or the *Hitches*
instrument in the Animation Hitches template) to confirm that the wallpaper
window presents at the video frame rate and that the window is opaque (no
blending with the system wallpaper underneath). In **Debug › View Debugging
› Rendering**-style overlays (Quartz Debug › *Show opaque regions*), the
wallpaper window must show as opaque.

### os_signpost

Add the *os_signpost* instrument, filter by subsystem
`com.yurisantos.wallpaper`. The `Decoding` interval is open exactly while a
player is running; it must close in every "nobody can see it" scenario.

## Scenarios to measure

Record each one for at least a minute, and note the result in the release
checklist.

| # | Scenario | How to set it up | Expected |
| --- | --- | --- | --- |
| 1 | One display, visible | One display, desktop visible, on AC | One `Decoding` interval open; hardware decode; CPU impact close to idle |
| 2 | Three displays, same video | Same asset assigned globally with three displays connected | Still exactly one `Decoding` interval (one decode shared by all displays); the three displays show the same frame |
| 3 | Desktop covered | Maximize a window (not fullscreen) so it covers the display | `reason=occluded`, `decoding stopped` within the polling interval; near-zero energy |
| 4 | Fullscreen | Put any app in fullscreen on the display | `reason=fullscreen`, window hidden, `decoding stopped` |
| 5 | Screen locked | Lock with Control-Command-Q | `reason=screenLocked`, `decoding stopped` immediately, regardless of preferences |
| 6 | Display asleep | Let the display sleep (`pmset displaysleepnow`) | `reason=displaysAsleep`, `decoding stopped` |
| 7 | Battery | Unplug the charger | `power_changed` reconcile in under a second; heavy assets switch to a still frame when "Reduce activity on battery" is on |
| 8 | Sleep / wake | Close the lid, reopen | No window is destroyed; the wallpaper is on screen immediately after wake |
| 9 | Dimming | Scenario 1, then scenario 2, each with Settings › Dimming at 0% and at 40% | App CPU unchanged (the dimming layer costs the app nothing per frame). Compare **WindowServer** CPU and GPU power between 0% and 40%: the difference decides whether dimming stays a layer or has to be baked into the rendition |
| 10 | Half speed | Scenario 2 with the wallpaper's speed at 0.5× | Half the frame-distribution callbacks per second and roughly half the media-engine activity of scenario 2 |
| 11 | Panorama | Two or more displays, "Stretch one video across the displays" on | Exactly one `Decoding` interval; the picture is continuous across the displays; same app CPU as scenario 2 |
| 12 | Playlist, desktop visible | An interval playlist of one minute, desktop visible | One wake-up per change (`reconcile … reason=playlist_advance`), nothing in between; at each change the previous `Decoding` interval closes before the next opens |
| 13 | Playlist, desktop hidden | Same playlist, then lock the screen (or cover the desktop) for several minutes | No `playlist_advance` reconcile and no `decoding started` while hidden; on return one `desktop_visible` reconcile shows the item that is right for the current time |
| 14 | Features at their defaults | Speed 1×, dimming 0%, no playlist, no panorama, unedited video | Indistinguishable from scenarios 1 and 2 measured before these features existed |

For scenario 2, check sync by filming two displays at 240 fps with a phone
and stepping through the footage, or by using a clip with a visible frame
counter. Leave it running for several hours and repeat: there must be no
drift, because all displays present the output of the same decoder.

## Charger connect / disconnect latency

```bash
log stream --predicate 'subsystem == "com.yurisantos.wallpaper" && category == "energy"'
```

Unplug the charger and compare the timestamp of `system event:
powerStateChanged` with the following `energy` line. The debounce is 120 ms,
so the mode change should land well under one second after the event.

## Dimming: layer versus baked

Dimming is a solid Core Animation layer above the video (see the header of
`WallpaperHostView.swift` for the reasoning). The app does no per-frame work
for it, but the window server blends one more layer, which could move the
video off a cheaper presentation path. Measure it before every release that
touches the layer tree:

```bash
sudo powermetrics --samplers tasks,gpu_power -i 5000 -n 12 | grep -E "WindowServer|WallSync|GPU Power"
```

Run it once with dimming at 0% and once at 40%, for scenario 1 (one display,
direct `AVPlayerLayer`) and scenario 2 (several displays, shared IOSurface).
If WindowServer or GPU power rises by more than measurement noise, the
alternative is to bake the dimming into the optimized rendition, at the cost
of a re-encode per adjustment and of the automatic dark-mode switch.

This comparison has **not** been run yet: it needs real hardware and `sudo`.
