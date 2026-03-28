# BAR Build Monitor

Real-time **Build Efficiency** and **Build Power** overlay for Beyond All Reason, with snapshot save/restore for third-party widget integration.

![Two charts stacked vertically on the left edge of the screen, gold for Build Efficiency and blue for Build Power, with matching stat cards to their right]

---

## Installation

1. Copy `bar_build_monitor.lua` to your BAR widgets folder:
   - **Windows:** `Documents\My Games\Spring\LuaUI\Widgets\`
   - **Linux:** `~/.spring/LuaUI/Widgets/`
2. In-game: **F11** → enable **BAR Build Monitor**
3. **F9** to show/hide

---

## Charts & Cards

| Element | What it shows |
|---|---|
| **Build Efficiency chart** | % of theoretical maximum metal pull that active builders are consuming (rolling avg) |
| **Build Power chart** | Sum of `buildSpeed` for all live constructor and factory units on your team |
| **Stat cards** | Live numeric values for each metric; stall warning appears on the efficiency card when metal demand outpaces supply |

---

## Controls

| Action | How |
|---|---|
| Show / hide all | **F9** |
| Enter edit mode | `/barbuild edit` |
| Move a chart or card | Edit mode → drag |
| Resize a chart or card | Edit mode → scroll wheel |
| Disable one element | Edit mode → right-click |

Charts are **locked by default** to prevent accidental moves during play.

---

## Commands

| Command | Effect |
|---|---|
| `/barbuild edit` | Toggle edit / locked mode |
| `/barbuild save` | Save layout and data to disk immediately |
| `/barbuild reset` | Delete config file (reload widget to restore defaults) |
| `/barbuild replay <secs>` | Replay the on-disk snapshot up to `<secs>` seconds |
| `/barbuild debug` | Print full state to the Spring console |

---

## Layout Saving

Positions, scales, and visibility are saved automatically on widget shutdown and restored next session.

**Config file location:**
- **Windows:** `Documents\My Games\Spring\bar_build_monitor_config.lua`
- **Linux:** `~/.spring/bar_build_monitor_config.lua`

The config file also stores a full data snapshot of both ring buffers so history survives a game restart.

---

## Third-Party Widget API

The widget exposes a public API table at `WG.BarBuildMonitor`. All functions are safe to call from any widget context.

### Quick reference

```lua
-- Export current history as a plain Lua table
local snap = WG.BarBuildMonitor.saveData()

-- Import a snapshot and render it, then continue live
WG.BarBuildMonitor.renderData(snap)

-- Write current history to the config file on disk
WG.BarBuildMonitor.saveSnapshot()

-- Replay the on-disk snapshot up to N seconds of recorded history
WG.BarBuildMonitor.replayUpTo(60)

-- Live value accessors
local eff   = WG.BarBuildMonitor.getBuildEfficiency()  -- float [0–100]
local bp    = WG.BarBuildMonitor.getBuildPower()        -- float (buildSpeed sum)
local stall = WG.BarBuildMonitor.getMetalStall()        -- 0=ok  1=warning  2=stall

-- Raw downsampled series (300 points by default)
local pts = WG.BarBuildMonitor.getSamples("buildEfficiency", 300)
local pts = WG.BarBuildMonitor.getSamples("buildPower",      300)

-- Timing metadata
local interval = WG.BarBuildMonitor.getSampleInterval()  -- seconds per sample (~0.167)
local total    = WG.BarBuildMonitor.getTotalSamples()     -- samples pushed since last reset
```

### `saveData()` — snapshot schema

`saveData()` returns a plain table with no metatables or closures. You own it; serialise it however you like.

```lua
{
  version            = "1.0",
  sampleIntervalSecs = 0.1667,   -- seconds between samples (BUILD_EFF_TICKS / GAME_FPS)
  totalSamples       = 720,      -- number of samples recorded
  buildEfficiency    = { 0, 12.4, 38.7, 65.1, ... },  -- chronological, [0–100]
  buildPower         = { 300, 375, 375, 525, ... },    -- chronological, buildSpeed units
}
```

Time for sample `i` (relative to the first sample) is simply:

```
t = (i - 1) * sampleIntervalSecs
```

No in-game wall-clock timestamps are stored — time is fully reconstructed from sample cadence.

### `renderData(snapshot)` — import and render

Pass any table that matches the schema above (from `saveData()` or constructed externally). The widget resets its ring buffers, replays all samples, seeds live stat values from the final sample, then resumes normal live collection seamlessly.

The call is **deferred** — the actual buffer mutation happens on the next `GameFrame` tick, so it is safe to call from `DrawScreen`, `Update`, or any other callback without risk of a mid-frame race.

---

### Full integration example

```lua
-- In your third-party widget:

local savedSnap = nil

function widget:GameFrame(n)
    -- Guard: only act if the monitor is loaded
    if not WG.BarBuildMonitor then return end

    -- Save a snapshot at the 5-minute mark
    if n == 30 * 60 * 5 then
        savedSnap = WG.BarBuildMonitor.saveData()
        Spring.Echo(string.format(
            "Snapshot saved: %d samples, %.1fs of history",
            savedSnap.totalSamples,
            savedSnap.totalSamples * savedSnap.sampleIntervalSecs
        ))
    end

    -- Read live values every second
    if n % 30 == 0 then
        local eff   = WG.BarBuildMonitor.getBuildEfficiency()
        local bp    = WG.BarBuildMonitor.getBuildPower()
        local stall = WG.BarBuildMonitor.getMetalStall()
        if stall == 2 then
            Spring.Echo(string.format("BUILD STALL — efficiency %.0f%%  BP %.0f", eff, bp))
        end
    end
end

-- Restore and render a saved snapshot (e.g. after a game reload or
-- when handing data to a post-game analysis widget):
function MyWidget.restoreSnapshot()
    if savedSnap and WG.BarBuildMonitor then
        WG.BarBuildMonitor.renderData(savedSnap)
    end
end

-- Serialise to disk yourself (example using a simple file write):
function MyWidget.persistToDisk(snap)
    local function ser(tbl, ind)
        ind = ind or ""
        local s = "{\n"
        for k, v in pairs(tbl) do
            local key = type(k) == "string" and ('["'..k..'"]') or ("["..k.."]")
            if     type(v) == "table"  then s = s..ind.."  "..key.." = "..ser(v, ind.."  ")..",\n"
            elseif type(v) == "number" then s = s..ind.."  "..key.." = "..v..",\n"
            elseif type(v) == "string" then s = s..ind.."  "..key..' = "'..v..'",\n' end
        end
        return s..ind.."}"
    end
    local f = io.open("my_build_snapshot.lua", "w")
    if f then f:write("return "..ser(snap)); f:close() end
end
```

---

## Technical Notes

**Sampling cadence:** Build efficiency and build power are sampled every 5 game frames (~0.167 s at 30 fps). The efficiency value is smoothed over a 3-sample rolling average to suppress single-frame noise.

**Builder re-evaluation:** The full team unit roster is re-scanned on every sample — no cached unit list is kept between calls. This means additions or removals made by third-party widgets (e.g. spawning or transferring units) are reflected within one sample interval.

**Ring buffer:** 120 seconds × 30 fps = 3 600 frames of raw history. Downsampled to 300 render points using bilinear interpolation (no nearest-neighbour jitter).

**Rendering:** Three GLSL programs handle anti-aliased line ribbons, animated area fills, and a scan-pulse grid. All geometry is cached in display lists; only the grid scan animation is drawn live each frame.

---

## Support

- BAR Discord: [discord.gg/NK7QWfVE9M](https://discord.gg/NK7QWfVE9M) → `#widgets`
- GitHub Issues

**Author:** FilthyMitch · **License:** MIT
