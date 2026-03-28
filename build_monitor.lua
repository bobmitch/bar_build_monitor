--[[
═══════════════════════════════════════════════════════════════════════════
    BAR BUILD MONITOR WIDGET
    v1.0 by FilthyMitch (derived from BAR Stats Charts v3.1)

    PURPOSE
    ───────
    A laser-focused widget that tracks and renders exactly two metrics for
    the local player's team:

        1. Build Efficiency  — percentage of theoretical maximum metal pull
                               that active builders are actually consuming.
        2. Build Power       — total buildSpeed of all constructor/factory
                               units currently alive on the team.

    Two matching stat cards show live numeric values beneath each chart.

    THIRD-PARTY API  (WG.BarBuildMonitor)
    ──────────────────────────────────────
    Four primary entry points for external widgets:

    1.  snapshot = WG.BarBuildMonitor.saveData()
        Returns a self-contained Lua table representing the current ring
        buffer in chronological order.  The table is a plain value — no
        metatables, no upvalue references — so it can be serialised to disk,
        sent over a network, or stored by the calling widget however it likes.
        Schema:
            {
              version            = "1.0",
              sampleIntervalSecs = <number>,   -- seconds between samples
              totalSamples       = <number>,   -- how many samples recorded
              buildEfficiency    = { ... },    -- array of floats [0-100]
              buildPower         = { ... },    -- array of floats (buildSpeed sum)
            }

    2.  WG.BarBuildMonitor.renderData(snapshot)
        Accepts a snapshot table previously returned by saveData() (or
        constructed externally to the same schema).  Resets the ring buffers,
        replays ALL samples from the snapshot, seeds live values from the
        final sample, then resumes live collection seamlessly from that point.
        Safe to call at any time; takes effect on the next GameFrame tick.

    3.  WG.BarBuildMonitor.replayUpTo(snapshotTimeSecs)
        Like renderData but trims the *file-loaded* snapshot (set at widget
        startup from the config file) to the requested time window before
        replaying.  Useful when the config file already holds a full-session
        history and the caller only wants to render a sub-window.

    4.  WG.BarBuildMonitor.saveSnapshot()
        Writes the current ring buffer to the config file on disk (same as
        the automatic save that occurs on widget shutdown).

    Live rendering re-evaluates which units are builders every update cycle
    because the calling widget may have added/removed units at any time.

    DATA SERIALISATION
    ──────────────────
    Time is stored as an offset in seconds from the first sample, calculated
    purely from sample cadence (SAMPLE_INTERVAL_FRAMES / GAME_FPS).  No
    in-game wall-clock time is embedded in saved records.

    Config + snapshot file (Lua table, human-readable):
        Windows:  Documents\My Games\Spring\bar_build_monitor_config.lua
        Linux:    ~/.spring/bar_build_monitor_config.lua

    The snapshot block looks like:

        snapshot = {
            sampleIntervalSecs = 0.333,   -- seconds per sample
            buildEfficiency    = { ... }, -- array of floats [0-100]
            buildPower         = { ... }, -- array of floats
        }

    Re-ingestion replays up to the requested timestamp, then live data
    appends seamlessly.

    RENDERING PIPELINE
    ──────────────────
    Three GLSL programs (line, fill, grid) identical to the parent widget's
    shader edition.  Display lists cache chrome and line geometry; the grid
    scan-pulse is drawn live every frame for smooth animation.

    PERFORMANCE NOTES
    ─────────────────
    • History ring buffer: 120 s × 30 fps = 3 600 frames.
    • Render resolution: 300 points (downsampled with bilinear lerp).
    • Build efficiency is re-sampled every BUILD_EFF_TICKS_PER_SAMPLE frames
      so that unit roster changes from external widgets are picked up promptly.
    • Builder unit table is rebuilt from scratch each efficiency sample so
      additions/removals made by third-party widgets are always reflected.
═══════════════════════════════════════════════════════════════════════════
]]

function widget:GetInfo()
    return {
        name    = "BAR Build Monitor",
        desc    = "Build Efficiency & Build Power charts with save/replay (v1.1)",
        author  = "FilthyMitch",
        date    = "2026",
        license = "MIT",
        layer   = 6,
        enabled = true,
    }
end

-- ═══════════════════════════════════════════════════════════════════════════
--  TABLE SERIALISATION
-- ═══════════════════════════════════════════════════════════════════════════

local function serializeTable(tbl, indent)
    indent    = indent or 0
    local ind = string.rep("  ", indent)
    local r   = "{\n"
    for k, v in pairs(tbl) do
        local kstr
        if type(k) == "string" then kstr = '["' .. k .. '"]'
        else                        kstr = "[" .. tostring(k) .. "]" end
        if     type(v) == "table"   then r = r .. ind .. "  " .. kstr .. " = " .. serializeTable(v, indent + 1) .. ",\n"
        elseif type(v) == "string"  then r = r .. ind .. "  " .. kstr .. ' = "' .. v .. '",\n'
        elseif type(v) == "boolean" then r = r .. ind .. "  " .. kstr .. " = " .. tostring(v) .. ",\n"
        elseif type(v) == "number"  then r = r .. ind .. "  " .. kstr .. " = " .. tostring(v) .. ",\n"
        end
    end
    return r .. ind .. "}"
end

-- ═══════════════════════════════════════════════════════════════════════════
--  CONSTANTS
-- ═══════════════════════════════════════════════════════════════════════════

local CONFIG_FILE = "bar_build_monitor_config.lua"

local GAME_FPS       = 30
local HISTORY_SECS   = 600
local HISTORY_SIZE   = GAME_FPS * HISTORY_SECS   -- 3 600 frames

local RENDER_POINTS  = 300
local MAX_CHART_FPS  = 30

-- How many game frames between build-efficiency samples.
-- Lower = more responsive to unit roster changes; higher = less CPU.
local BUILD_EFF_TICKS = 5   -- ~6 samples/sec at 30fps

-- Rolling-average window for build efficiency (in samples).
local BUILD_EFF_WINDOW = 3

-- Snap grid for drag-and-drop positioning.
local SNAP_GRID = 20

-- X-axis tick spacing.
local BASE_TICK_SECS = 30
local MIN_TICK_PX    = 44

-- Shader line geometry parameters.
local LINE_HALF_WIDTH = 0.6
local LINE_GLOW_RADIUS = 3.0

-- Chart & card dimensions.
local CHART_WIDTH  = 300
local CHART_HEIGHT = 180
local PAD          = { left = 40, right = 15, top = 15, bottom = 25 }
local CARD_WIDTH   = 140
local CARD_HEIGHT  = 70

-- Palette (same as parent widget).
local C = {
    bg        = { 0.031, 0.047, 0.078, 0.72 },
    border    = { 0.353, 0.706, 1.000, 0.18 },
    borderHot = { 0.353, 0.706, 1.000, 0.55 },
    grid      = { 0.353, 0.706, 1.000, 0.08 },
    gridBase  = { 0.353, 0.706, 1.000, 0.22 },
    muted     = { 0.627, 0.745, 0.863, 0.55 },
    accent    = { 0.290, 0.706, 1.000, 1.00 },
    gold      = { 0.941, 0.753, 0.251, 1.00 },
    danger    = { 1.000, 0.231, 0.361, 1.00 },
    success   = { 0.188, 0.941, 0.627, 1.00 },
}

-- ═══════════════════════════════════════════════════════════════════════════
--  GLOBAL STATE
-- ═══════════════════════════════════════════════════════════════════════════

local vsx, vsy         = Spring.GetViewGeometry()
local widgetEnabled    = true
local chartsInteractive = false
local chartsReady      = false

local myTeamID         = nil

-- ── Ring buffers (one per series) ─────────────────────────────────────────
-- Series keys: "buildEfficiency", "buildPower"
local SERIES = { "buildEfficiency", "buildPower" }

local ringBuf  = {}   -- ringBuf[key][i] = value
local ringHead = {}   -- next-write position
local ringFull = {}   -- has the buffer wrapped?

local function initRing()
    for _, k in ipairs(SERIES) do
        ringBuf[k]  = {}
        ringHead[k] = 1
        ringFull[k] = false
        for i = 1, HISTORY_SIZE do ringBuf[k][i] = 0 end
    end
end

local function ringPush(key, value)
    local h         = ringHead[key]
    ringBuf[key][h] = value
    h               = h + 1
    if h > HISTORY_SIZE then h = 1; ringFull[key] = true end
    ringHead[key]   = h
end

-- Returns: startIdx, count
local function ringRange(key)
    local h    = ringHead[key]
    local full = ringFull[key]
    return full and h or 1, full and HISTORY_SIZE or (h - 1)
end

-- Bilinear-interpolated downsample to numPts output points.
local function ringSample(key, numPts)
    local startIdx, count = ringRange(key)
    if count <= 0 then return {} end
    local buf = ringBuf[key]
    local n   = math.min(numPts, count)
    if n <= 0 then return {} end
    if n == 1 then
        local idx = ((startIdx - 1) % HISTORY_SIZE) + 1
        return { buf[idx] }
    end
    local pts     = {}
    local countM1 = count - 1
    for i = 1, n do
        local fi  = (i - 1) / (n - 1) * countM1
        local lo  = math.floor(fi)
        local t   = fi - lo
        local hi  = math.min(lo + 1, countM1)
        local idxA = ((startIdx - 1 + lo) % HISTORY_SIZE) + 1
        local idxB = ((startIdx - 1 + hi) % HISTORY_SIZE) + 1
        pts[i]    = buf[idxA] + t * (buf[idxB] - buf[idxA])
    end
    return pts
end

-- ── Live stats ─────────────────────────────────────────────────────────────
local liveBuildEfficiency = 0
local liveBuildPower      = 0
local liveMetalStall      = 0   -- 0=ok 1=warning 2=stall

-- Build efficiency rolling-average state.
local beTickCounter = 0
local beSamples     = {}
local beIndex       = 0
local beCount       = 0
for i = 1, BUILD_EFF_WINDOW do beSamples[i] = 0 end

-- Cached per-unit build data to avoid UnitDef lookups every frame.
-- NOTE: Intentionally NOT cached between efficiency samples so that
--       external widget changes (unit additions/removals) are always seen.
local maxMetalCache = {}   -- maxMetalCache[builderDefID][targetDefID] = metalPullMax

-- ── Snapshot / replay state ────────────────────────────────────────────────
-- replayPending  : set by replayUpTo() — uses the file-loaded snapshotData
-- renderPending  : set by renderData() — uses a caller-supplied table
-- Both are consumed on the next GameFrame tick to avoid mid-frame ring edits.
local replayPending    = false
local replayUpToSecs   = nil
local snapshotData     = nil   -- loaded from config file at startup

local renderPending    = false
local renderDataTable  = nil   -- supplied directly by caller via renderData()

-- Total samples pushed since widget init (for serialisation offset).
local totalSamplesPushed = 0
local sampleIntervalSecs = BUILD_EFF_TICKS / GAME_FPS   -- seconds per sample

-- ── Display-list handles ───────────────────────────────────────────────────
local chromeList  = nil
local linesList   = nil
local overlayList = nil

local chromeDirty  = true
local linesDirty   = true
local overlayDirty = true
local linesLastRebuild = nil

-- Animation timer.
local widgetTimer = nil

-- ── Chart / card layout tables ─────────────────────────────────────────────
-- These are simple tables, not objects, to keep the code minimal.
local chartBE   = {}   -- build efficiency chart
local chartBP   = {}   -- build power chart
local cardBE    = {}   -- build efficiency stat card
local cardBP    = {}   -- build power stat card

-- ── Computed range cache (updated each lines rebuild) ─────────────────────
local rangeBE = { mn = 0, mx = 100, r = 100 }
local rangeBP = { mn = 0, mx = 1,   r = 1   }

-- ═══════════════════════════════════════════════════════════════════════════
--  HELPERS
-- ═══════════════════════════════════════════════════════════════════════════

local function snapTo(v)
    return math.floor(v / SNAP_GRID + 0.5) * SNAP_GRID
end

local function fmtNum(n)
    if     n >= 1e6   then return string.format("%.1fM", n / 1e6)
    elseif n >= 1e4   then return string.format("%.0fK", n / 1e3)
    else                   return string.format("%d", math.floor(n + 0.5)) end
end

local function fmtPct(n)
    return string.format("%.0f%%", n)
end

local function elapsedSecs()
    if not widgetTimer then return 0 end
    return Spring.DiffTimers(Spring.GetTimer(), widgetTimer)
end

local function drawRoundedRect(x, y, w, h, r, filled)
    if filled then
        gl.BeginEnd(GL.QUADS, function()
            gl.Vertex(x+r, y);     gl.Vertex(x+w-r, y)
            gl.Vertex(x+w-r, y+h); gl.Vertex(x+r, y+h)
            gl.Vertex(x, y+r);     gl.Vertex(x+w, y+r)
            gl.Vertex(x+w, y+h-r); gl.Vertex(x, y+h-r)
        end)
        local segs = 6
        for i = 0, segs-1 do
            local a1 = (math.pi/2)*(i/segs)
            local a2 = (math.pi/2)*((i+1)/segs)
            gl.BeginEnd(GL.TRIANGLES, function()
                gl.Vertex(x+r,   y+r);   gl.Vertex(x+r-r*math.cos(a1),   y+r-r*math.sin(a1));   gl.Vertex(x+r-r*math.cos(a2),   y+r-r*math.sin(a2))
            end)
            gl.BeginEnd(GL.TRIANGLES, function()
                gl.Vertex(x+w-r, y+r);   gl.Vertex(x+w-r+r*math.sin(a1), y+r-r*math.cos(a1));   gl.Vertex(x+w-r+r*math.sin(a2), y+r-r*math.cos(a2))
            end)
            gl.BeginEnd(GL.TRIANGLES, function()
                gl.Vertex(x+w-r, y+h-r); gl.Vertex(x+w-r+r*math.cos(a1), y+h-r+r*math.sin(a1)); gl.Vertex(x+w-r+r*math.cos(a2), y+h-r+r*math.sin(a2))
            end)
            gl.BeginEnd(GL.TRIANGLES, function()
                gl.Vertex(x+r,   y+h-r); gl.Vertex(x+r-r*math.sin(a1),   y+h-r+r*math.cos(a1)); gl.Vertex(x+r-r*math.sin(a2),   y+h-r+r*math.cos(a2))
            end)
        end
    else
        gl.BeginEnd(GL.LINE_LOOP, function()
            gl.Vertex(x+r, y); gl.Vertex(x+w-r, y)
            for i = 0, 6 do local a=(math.pi/2)*(i/6); gl.Vertex(x+w-r+r*math.sin(a), y+r-r*math.cos(a)) end
            gl.Vertex(x+w, y+r); gl.Vertex(x+w, y+h-r)
            for i = 0, 6 do local a=(math.pi/2)*(i/6); gl.Vertex(x+w-r+r*math.cos(a), y+h-r+r*math.sin(a)) end
            gl.Vertex(x+w-r, y+h); gl.Vertex(x+r, y+h)
            for i = 0, 6 do local a=(math.pi/2)*(i/6); gl.Vertex(x+r-r*math.sin(a), y+h-r+r*math.cos(a)) end
            gl.Vertex(x, y+h-r); gl.Vertex(x, y+r)
            for i = 0, 6 do local a=(math.pi/2)*(i/6); gl.Vertex(x+r-r*math.cos(a), y+r-r*math.sin(a)) end
        end)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
--  SHADERS
-- ═══════════════════════════════════════════════════════════════════════════

local shaderLine, shaderFill, shaderGrid = nil, nil, nil
local uLine, uFill, uGrid = {}, {}, {}

local LINE_VS = [[
#version 120
varying float vDist;
void main() {
    vDist       = gl_Color.r;
    gl_Position = gl_ModelViewProjectionMatrix * gl_Vertex;
}
]]

local LINE_FS = [[
#version 120
uniform vec4  uColor;
uniform float uHalfWidth;
uniform float uGlowRadius;
varying float vDist;
void main() {
    float d    = abs(vDist);
    float core = 1.0 - smoothstep(uHalfWidth - 1.0, uHalfWidth + 1.0, d);
    float outerDist = max(0.0, d - uHalfWidth);
    float bloom = exp(-outerDist * outerDist / (uGlowRadius * 0.5)) * 0.4;
    float alpha = clamp(core + bloom, 0.0, 1.0);
    float centreBright = max(0.0, 1.0 - d / uHalfWidth) * 0.15;
    vec3  col = uColor.rgb + centreBright;
    gl_FragColor = vec4(col, uColor.a * alpha);
}
]]

local FILL_VS = [[
#version 120
varying float vT;
varying float vX;
void main() {
    vT          = gl_Color.r;
    vX          = gl_Vertex.x;
    gl_Position = gl_ModelViewProjectionMatrix * gl_Vertex;
}
]]

local FILL_FS = [[
#version 120
uniform vec4  uColor;
uniform float uTime;
uniform float uChartX;
uniform float uChartW;
varying float vT;
varying float vX;
void main() {
    float alpha  = vT * vT * 0.55;
    float nx     = (vX - uChartX) / max(uChartW, 1.0);
    float phase  = nx - uTime * 0.045;
    float band   = sin(phase * 3.14159 * 2.0);
    band         = clamp(band * 0.5 + 0.5, 0.0, 1.0);
    band         = pow(band, 12.0);
    float shimmer = band * 0.18 * vT;
    gl_FragColor  = vec4(uColor.rgb, (alpha + shimmer) * uColor.a);
}
]]

local GRID_VS = [[
#version 120
varying vec2 vPos;
void main() {
    vPos        = gl_Vertex.xy;
    gl_Position = gl_ModelViewProjectionMatrix * gl_Vertex;
}
]]

local GRID_FS = [[
#version 120
uniform vec4  uColor;
uniform float uTime;
uniform float uChartY;
uniform float uChartH;
varying vec2  vPos;
void main() {
    float ny    = (vPos.y - uChartY) / max(uChartH, 1.0);
    float pulse = mod(uTime * 0.25, 1.0);
    float dist  = abs(ny - pulse);
    float bright = exp(-dist * dist * 120.0) * 0.6;
    float a = uColor.a + bright;
    gl_FragColor = vec4(uColor.rgb + bright * 0.4, clamp(a, 0.0, 1.0));
}
]]

local function compileShader(vs, fs)
    local sh = gl.CreateShader({ vertex = vs, fragment = fs })
    if not sh then
        Spring.Echo("BAR Build Monitor: shader compile FAILED — " .. (gl.GetShaderLog() or ""))
        return nil
    end
    return sh
end

local function initShaders()
    shaderLine = compileShader(LINE_VS, LINE_FS)
    if shaderLine then
        uLine.color      = gl.GetUniformLocation(shaderLine, "uColor")
        uLine.halfWidth  = gl.GetUniformLocation(shaderLine, "uHalfWidth")
        uLine.glowRadius = gl.GetUniformLocation(shaderLine, "uGlowRadius")
    end

    shaderFill = compileShader(FILL_VS, FILL_FS)
    if shaderFill then
        uFill.color  = gl.GetUniformLocation(shaderFill, "uColor")
        uFill.time   = gl.GetUniformLocation(shaderFill, "uTime")
        uFill.chartX = gl.GetUniformLocation(shaderFill, "uChartX")
        uFill.chartW = gl.GetUniformLocation(shaderFill, "uChartW")
    end

    shaderGrid = compileShader(GRID_VS, GRID_FS)
    if shaderGrid then
        uGrid.color  = gl.GetUniformLocation(shaderGrid, "uColor")
        uGrid.time   = gl.GetUniformLocation(shaderGrid, "uTime")
        uGrid.chartY = gl.GetUniformLocation(shaderGrid, "uChartY")
        uGrid.chartH = gl.GetUniformLocation(shaderGrid, "uChartH")
    end

    Spring.Echo("BAR Build Monitor: shaders initialised")
end

local function deleteShaders()
    if shaderLine then gl.DeleteShader(shaderLine); shaderLine = nil end
    if shaderFill then gl.DeleteShader(shaderFill); shaderFill = nil end
    if shaderGrid then gl.DeleteShader(shaderGrid); shaderGrid = nil end
end

-- ═══════════════════════════════════════════════════════════════════════════
--  SHADER DRAW HELPERS  (called inside gl.CreateList)
-- ═══════════════════════════════════════════════════════════════════════════

local function shaderDrawLine(pts, cX, cY, cW, cH, mn, r, col, halfW, glowR)
    if not shaderLine then return end
    local n = #pts
    if n < 2 then return end

    gl.UseShader(shaderLine)
    if uLine.color      then gl.Uniform(uLine.color,      col[1], col[2], col[3], col[4] or 1) end
    if uLine.halfWidth  then gl.Uniform(uLine.halfWidth,  halfW) end
    if uLine.glowRadius then gl.Uniform(uLine.glowRadius, glowR) end

    local totalHW = halfW + glowR + 1.0
    local sx, sy  = {}, {}
    for i = 1, n do
        sx[i] = cX + cW - ((n - i) / (n - 1)) * cW
        sy[i] = cY + ((pts[i] - mn) / r) * cH
        sy[i] = math.max(cY - totalHW, math.min(cY + cH + totalHW, sy[i]))
    end

    gl.BeginEnd(GL.TRIANGLES, function()
        for i = 1, n - 1 do
            local x0, y0 = sx[i],   sy[i]
            local x1, y1 = sx[i+1], sy[i+1]
            local dx = x1 - x0; local dy = y1 - y0
            local len = math.sqrt(dx*dx + dy*dy); if len < 1e-4 then len = 1e-4 end
            local px = (-dy / len) * totalHW
            local py = ( dx / len) * totalHW
            gl.Color(-totalHW,0,0,1); gl.Vertex(x0-px, y0-py)
            gl.Color( totalHW,0,0,1); gl.Vertex(x0+px, y0+py)
            gl.Color(-totalHW,0,0,1); gl.Vertex(x1-px, y1-py)
            gl.Color( totalHW,0,0,1); gl.Vertex(x1+px, y1+py)
            gl.Color(-totalHW,0,0,1); gl.Vertex(x1-px, y1-py)
            gl.Color( totalHW,0,0,1); gl.Vertex(x0+px, y0+py)
        end
    end)

    gl.UseShader(0)
end

local function shaderDrawFill(pts, cX, cY, cW, cH, mn, r, col, t)
    if not shaderFill then return end
    local n = #pts; if n < 2 then return end

    gl.UseShader(shaderFill)
    if uFill.color  then gl.Uniform(uFill.color,  col[1], col[2], col[3], col[4] or 1) end
    if uFill.time   then gl.Uniform(uFill.time,   t) end
    if uFill.chartX then gl.Uniform(uFill.chartX, cX) end
    if uFill.chartW then gl.Uniform(uFill.chartW, cW) end

    gl.BeginEnd(GL.TRIANGLE_STRIP, function()
        for i = 1, n do
            local x  = cX + cW - ((n - i) / (n - 1)) * cW
            local y  = cY + ((pts[i] - mn) / r) * cH
            y        = math.max(cY, math.min(cY + cH, y))
            local tv = math.max(0, (y - cY) / math.max(cH, 1))
            gl.Color(0, 0, 0, 1);   gl.Vertex(x, cY)
            gl.Color(tv, 0, 0, 1);  gl.Vertex(x, y)
        end
    end)

    gl.UseShader(0)
end

local function shaderDrawGridLine(x0, y0, x1, y1, cY, cH, col, t)
    if shaderGrid then
        gl.UseShader(shaderGrid)
        if uGrid.color  then gl.Uniform(uGrid.color,  col[1], col[2], col[3], col[4]) end
        if uGrid.time   then gl.Uniform(uGrid.time,   t) end
        if uGrid.chartY then gl.Uniform(uGrid.chartY, cY) end
        if uGrid.chartH then gl.Uniform(uGrid.chartH, cH) end
        gl.LineWidth(1.0)
        gl.BeginEnd(GL.LINES, function() gl.Vertex(x0, y0); gl.Vertex(x1, y1) end)
        gl.UseShader(0)
    else
        gl.Color(col[1], col[2], col[3], col[4])
        gl.BeginEnd(GL.LINES, function() gl.Vertex(x0, y0); gl.Vertex(x1, y1) end)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
--  X-AXIS TIME LABELS
-- ═══════════════════════════════════════════════════════════════════════════

local function fmtTimestamp(secs)
    local m = math.floor(secs / 60)
    local s = secs % 60
    if m == 0 then return string.format(":%02d", s)
    else            return string.format("%d:%02d", m, s) end
end

local function drawTimeAxis(cX, cW, cY, windowSecs, nowSecs, alpha)
    if windowSecs <= 0 then return end
    local tickSecs = BASE_TICK_SECS
    local pxPerSec = cW / windowSecs
    while (tickSecs * pxPerSec) < MIN_TICK_PX do
        tickSecs = tickSecs * 2
        if tickSecs > windowSecs then return end
    end
    local leftSecs  = nowSecs - windowSecs
    local firstTick = math.ceil(leftSecs / tickSecs) * tickSecs
    local mc = C.muted
    local t  = firstTick
    while t <= nowSecs do
        local frac = (t - leftSecs) / windowSecs
        local xPos = cX + frac * cW
        gl.Color(mc[1], mc[2], mc[3], mc[4]*0.7*alpha)
        gl.LineWidth(1.0)
        gl.BeginEnd(GL.LINES, function()
            gl.Vertex(xPos, cY); gl.Vertex(xPos, cY - 4)
        end)
        gl.Color(mc[1], mc[2], mc[3], mc[4]*0.85*alpha)
        gl.Text(fmtTimestamp(math.floor(t + 0.5)), xPos, cY - 13, 8, "co")
        t = t + tickSecs
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
--  LAYOUT INIT
-- ═══════════════════════════════════════════════════════════════════════════

local function buildLayout()
    -- Charts stacked vertically on the left side.
    chartBE = {
        id      = "chart-build-efficiency",
        label   = "BUILD EFFICIENCY",
        icon    = "🔧",
        x       = 20,
        y       = vsy - CHART_HEIGHT - 20,
        width   = CHART_WIDTH,
        height  = CHART_HEIGHT,
        scale   = 1.0,
        enabled = true,
        visible = true,
        isDragging = false,
        dragStartX = 0, dragStartY = 0,
        isHovered  = false,
        seriesKey  = "buildEfficiency",
        color      = C.gold,
        isPercent  = true,
    }

    chartBP = {
        id      = "chart-build-power",
        label   = "BUILD POWER",
        icon    = "⚙",
        x       = 20,
        y       = vsy - CHART_HEIGHT * 2 - 40,
        width   = CHART_WIDTH,
        height  = CHART_HEIGHT,
        scale   = 1.0,
        enabled = true,
        visible = true,
        isDragging = false,
        dragStartX = 0, dragStartY = 0,
        isHovered  = false,
        seriesKey  = "buildPower",
        color      = C.accent,
        isPercent  = false,
    }

    -- Cards to the right of / below the charts.
    local cardX = 20 + CHART_WIDTH + 10
    cardBE = {
        id      = "card-build-efficiency",
        label   = "BUILD EFF",
        icon    = "🔧",
        x       = cardX,
        y       = vsy - CHART_HEIGHT - 20,
        scale   = 1.0,
        enabled = true,
        visible = true,
        isDragging = false,
        dragStartX = 0, dragStartY = 0,
        isHovered  = false,
        color      = C.gold,
        isPercent  = true,
    }

    cardBP = {
        id      = "card-build-power",
        label   = "BUILD PWR",
        icon    = "⚙",
        x       = cardX,
        y       = vsy - CHART_HEIGHT * 2 - 40,
        scale   = 1.0,
        enabled = true,
        visible = true,
        isDragging = false,
        dragStartX = 0, dragStartY = 0,
        isHovered  = false,
        color      = C.accent,
        isPercent  = false,
    }
end

-- ═══════════════════════════════════════════════════════════════════════════
--  COMPUTE RANGE (for a chart)
-- ═══════════════════════════════════════════════════════════════════════════

local function computeRange(chart)
    local pts = ringSample(chart.seriesKey, RENDER_POINTS)
    if #pts == 0 then return nil end
    local mn, mx = math.huge, -math.huge
    for _, v in ipairs(pts) do
        if v and not (v ~= v) then
            if v < mn then mn = v end
            if v > mx then mx = v end
        end
    end
    if mn == math.huge then return nil end
    if chart.isPercent then
        mn = 0; mx = 100
    else
        mn = 0
        local p = mx > 0 and mx * 0.12 or 100
        mx = mx + p
    end
    local r = mx - mn
    if r == 0 then r = 1 end
    return mn, mx, r
end

-- ═══════════════════════════════════════════════════════════════════════════
--  BUILD EFFICIENCY SAMPLING
--  Re-scans all team units every call so external widget changes are visible.
-- ═══════════════════════════════════════════════════════════════════════════

local function sampleBuildEfficiency()
    if not myTeamID then return 0, 0 end

    local units = Spring.GetTeamUnits(myTeamID) or {}
    local effSum, effCount = 0, 0
    local totalBP = 0

    for _, uid in ipairs(units) do
        local udid = Spring.GetUnitDefID(uid)
        local ud   = udid and UnitDefs[udid]
        if ud and ud.isBuilder then
            local bp = ud.buildSpeed or 0
            if bp > 0 then
                totalBP = totalBP + bp
                local targetID = Spring.GetUnitIsBuilding(uid)
                if targetID then
                    local tDefID = Spring.GetUnitDefID(targetID)
                    local tud    = tDefID and UnitDefs[tDefID]
                    local maxMetal = 0
                    if tud then
                        -- Cache to avoid repeated division.
                        if not maxMetalCache[udid] then maxMetalCache[udid] = {} end
                        if maxMetalCache[udid][tDefID] == nil then
                            local bt = math.max(tud.buildTime or 1, 1)
                            maxMetalCache[udid][tDefID] = (bp / bt) * (tud.metalCost or 0)
                        end
                        maxMetal = maxMetalCache[udid][tDefID]
                    end
                    local _, mPull = Spring.GetUnitResources(uid, "metal")
                    local mUsing   = mPull or 0
                    if maxMetal > 0 then
                        effSum   = effSum + math.min(1.0, mUsing / maxMetal)
                        effCount = effCount + 1
                    end
                end
            end
        end
    end

    -- Invalidate maxMetalCache each cycle so target changes are picked up.
    maxMetalCache = {}

    local eff = (effCount > 0) and ((effSum / effCount) * 100) or 0
    return eff, totalBP
end

local function pushEffSample(rawEff, rawBP)
    -- Rolling average for efficiency.
    beIndex = (beIndex % BUILD_EFF_WINDOW) + 1
    beSamples[beIndex] = rawEff
    if beCount < BUILD_EFF_WINDOW then beCount = beCount + 1 end
    local sum = 0
    for i = 1, beCount do sum = sum + (beSamples[i] or 0) end
    liveBuildEfficiency = sum / beCount
    liveBuildPower      = rawBP

    ringPush("buildEfficiency", liveBuildEfficiency)
    ringPush("buildPower",      liveBuildPower)
    totalSamplesPushed = totalSamplesPushed + 1

    linesDirty   = true
    overlayDirty = true
end

-- ═══════════════════════════════════════════════════════════════════════════
--  METAL STALL DETECTION
-- ═══════════════════════════════════════════════════════════════════════════

local function updateMetalStall()
    if not myTeamID then return end
    local _, _, mpull, _, mexp = Spring.GetTeamResources(myTeamID, "metal")
    if mpull and mpull > 1 then
        local ratio = (mexp or 0) / mpull
        if     ratio < 0.60 then liveMetalStall = 2
        elseif ratio < 0.98 then liveMetalStall = 1
        else                     liveMetalStall = 0 end
    else
        liveMetalStall = 0
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
--  SNAPSHOT / SERIALISATION
-- ═══════════════════════════════════════════════════════════════════════════

-- Drain the ring buffer for `key` into a flat chronological array.
-- This is used both by saveConfig (file) and saveData (in-memory return).
local function drainRing(key)
    local startIdx, count = ringRange(key)
    if count == 0 then return {} end
    local out = {}
    for i = 0, count - 1 do
        local idx  = ((startIdx - 1 + i) % HISTORY_SIZE) + 1
        out[i + 1] = ringBuf[key][idx]
    end
    return out
end

-- ─────────────────────────────────────────────────────────────────────────
--  saveData()  — public API, returns a plain table the caller can keep
-- ─────────────────────────────────────────────────────────────────────────
-- Returns a self-contained snapshot of the current ring buffers.
-- The returned table has no metatables or upvalue closures; it is safe to
-- serialise with any standard Lua serialiser or store in a calling widget's
-- own data structures.
--
-- Schema:
--   {
--     version            = "1.0",
--     sampleIntervalSecs = <number>,
--     totalSamples       = <number>,
--     buildEfficiency    = { [1]=float, [2]=float, ... },
--     buildPower         = { [1]=float, [2]=float, ... },
--   }
local function saveData()
    local beArr = drainRing("buildEfficiency")
    local bpArr = drainRing("buildPower")
    return {
        version            = "1.0",
        sampleIntervalSecs = sampleIntervalSecs,
        totalSamples       = totalSamplesPushed,
        buildEfficiency    = beArr,
        buildPower         = bpArr,
    }
end

-- ─────────────────────────────────────────────────────────────────────────
--  renderDataFromTable(tbl)  — internal; consumes a saveData()-style table
-- ─────────────────────────────────────────────────────────────────────────
-- Replays ALL samples from `tbl` (no time-window trimming — the caller
-- chose what to include), then seeds live values from the final sample.
-- Ring buffers are reset first so there is no overlap with previous data.
local function renderDataFromTable(tbl)
    if type(tbl) ~= "table" then
        Spring.Echo("BAR Build Monitor: renderData — invalid argument (expected table)")
        return
    end

    local interval = tbl.sampleIntervalSecs or sampleIntervalSecs
    local beArr    = tbl.buildEfficiency or {}
    local bpArr    = tbl.buildPower      or {}
    local count    = math.max(#beArr, #bpArr)

    if count == 0 then
        Spring.Echo("BAR Build Monitor: renderData — snapshot contains no samples")
        return
    end

    -- Reset ring buffers and rolling-average state.
    initRing()
    totalSamplesPushed  = 0
    beIndex             = 0
    beCount             = 0
    for i = 1, BUILD_EFF_WINDOW do beSamples[i] = 0 end

    for i = 1, count do
        local beVal = beArr[i] or 0
        local bpVal = bpArr[i] or 0
        ringPush("buildEfficiency", beVal)
        ringPush("buildPower",      bpVal)
        totalSamplesPushed = totalSamplesPushed + 1
    end

    -- Seed live values from the last replayed sample so cards show a
    -- sensible number immediately, before the first live sample arrives.
    liveBuildEfficiency = beArr[count] or 0
    liveBuildPower      = bpArr[count] or 0

    -- Also update the rolling-average window to match so there is no
    -- discontinuity spike when the first live sample is pushed.
    for i = 1, BUILD_EFF_WINDOW do
        beSamples[i] = liveBuildEfficiency
    end
    beCount = BUILD_EFF_WINDOW

    linesDirty   = true
    chromeDirty  = true
    overlayDirty = true

    Spring.Echo(string.format(
        "BAR Build Monitor: renderData — loaded %d samples (%.1fs @ %.3fs/sample)",
        count, count * interval, interval))
end

local function saveConfig()
    -- drainRing is defined at module level above.
    local config = {
        version           = "1.0",
        enabled           = widgetEnabled,
        chartsInteractive = chartsInteractive,
        charts = {
            ["chart-build-efficiency"] = { x=chartBE.x, y=chartBE.y, scale=chartBE.scale, visible=chartBE.visible, enabled=chartBE.enabled },
            ["chart-build-power"]      = { x=chartBP.x, y=chartBP.y, scale=chartBP.scale, visible=chartBP.visible, enabled=chartBP.enabled },
        },
        cards = {
            ["card-build-efficiency"] = { x=cardBE.x, y=cardBE.y, scale=cardBE.scale, visible=cardBE.visible, enabled=cardBE.enabled },
            ["card-build-power"]      = { x=cardBP.x, y=cardBP.y, scale=cardBP.scale, visible=cardBP.visible, enabled=cardBP.enabled },
        },
        snapshot = {
            sampleIntervalSecs = sampleIntervalSecs,
            buildEfficiency    = drainRing("buildEfficiency"),
            buildPower         = drainRing("buildPower"),
        },
    }

    local f = io.open(CONFIG_FILE, "w")
    if f then
        f:write("return " .. serializeTable(config, 0))
        f:close()
        Spring.Echo("BAR Build Monitor: config saved (" .. totalSamplesPushed .. " samples)")
    else
        Spring.Echo("BAR Build Monitor: config save FAILED (write permission?)")
    end
end

local function loadConfig()
    if not VFS.FileExists(CONFIG_FILE) then return end
    local fc = VFS.LoadFile(CONFIG_FILE)
    if not fc then return end
    local chunk, err = loadstring(fc)
    if not chunk then
        Spring.Echo("BAR Build Monitor: config parse error — " .. tostring(err))
        return
    end
    local ok, result = pcall(chunk)
    if not ok or type(result) ~= "table" then
        Spring.Echo("BAR Build Monitor: invalid config")
        return
    end

    if result.enabled           ~= nil then widgetEnabled     = result.enabled           end
    if result.chartsInteractive ~= nil then chartsInteractive = result.chartsInteractive end

    local function applyElem(elem, cfg)
        if not cfg then return end
        if cfg.x       ~= nil then elem.x       = cfg.x       end
        if cfg.y       ~= nil then elem.y       = cfg.y       end
        if cfg.scale   ~= nil then elem.scale   = cfg.scale   end
        if cfg.visible ~= nil then elem.visible = cfg.visible end
        if cfg.enabled ~= nil then elem.enabled = cfg.enabled end
    end

    if result.charts then
        applyElem(chartBE, result.charts["chart-build-efficiency"])
        applyElem(chartBP, result.charts["chart-build-power"])
    end
    if result.cards then
        applyElem(cardBE, result.cards["card-build-efficiency"])
        applyElem(cardBP, result.cards["card-build-power"])
    end

    -- Stash snapshot for possible replay (third-party API call).
    snapshotData = result.snapshot

    Spring.Echo("BAR Build Monitor: config loaded")
end

-- ─────────────────────────────────────────────────────────────────────────
--  REPLAY API
--  Called by third-party widgets to inject saved data up to `upToSecs`
--  seconds (measured from first saved sample), then switch to live mode.
-- ─────────────────────────────────────────────────────────────────────────

local function replaySnapshot(upToSecs)
    if not snapshotData then
        Spring.Echo("BAR Build Monitor: replayUpTo called but no snapshot available")
        return
    end

    local interval = snapshotData.sampleIntervalSecs or sampleIntervalSecs
    local beArr    = snapshotData.buildEfficiency or {}
    local bpArr    = snapshotData.buildPower      or {}
    local maxIdx   = math.max(#beArr, #bpArr)

    -- How many samples fit within the requested window?
    local maxSamples = (interval > 0) and math.floor(upToSecs / interval) or maxIdx
    maxSamples = math.min(maxSamples, maxIdx)

    -- Reset ring buffers before replay.
    initRing()
    totalSamplesPushed = 0

    for i = 1, maxSamples do
        local beVal = beArr[i] or 0
        local bpVal = bpArr[i] or 0
        ringPush("buildEfficiency", beVal)
        ringPush("buildPower",      bpVal)
        totalSamplesPushed = totalSamplesPushed + 1
    end

    -- Seed live values from last replayed sample.
    liveBuildEfficiency = beArr[maxSamples] or 0
    liveBuildPower      = bpArr[maxSamples] or 0

    linesDirty   = true
    chromeDirty  = true
    overlayDirty = true

    Spring.Echo(string.format(
        "BAR Build Monitor: replayed %d samples (%.1fs of %.1fs requested)",
        maxSamples, maxSamples * interval, upToSecs))
end

-- ═══════════════════════════════════════════════════════════════════════════
--  DISPLAY-LIST BUILDERS
-- ═══════════════════════════════════════════════════════════════════════════

local function freeLists()
    if chromeList  then gl.DeleteList(chromeList);  chromeList  = nil end
    if linesList   then gl.DeleteList(linesList);   linesList   = nil end
    if overlayList then gl.DeleteList(overlayList); overlayList = nil end
end

-- ── Chrome: background panels, borders, labels, Y-axis ───────────────────

local function buildChrome(chart, pts, mn, r, isPercent)
    local w  = chart.width
    local h  = chart.height
    local cX = PAD.left
    local cY = PAD.bottom
    local cW = w - PAD.left - PAD.right
    local cH = h - PAD.top  - PAD.bottom

    gl.PushMatrix()
    gl.Translate(chart.x, chart.y, 0)
    gl.Scale(chart.scale, chart.scale, 1)

    gl.Color(C.bg[1], C.bg[2], C.bg[3], C.bg[4])
    drawRoundedRect(0, 0, w, h, 4, true)
    gl.Color(C.border[1], C.border[2], C.border[3], C.border[4])
    gl.LineWidth(1)
    drawRoundedRect(0.5, 0.5, w-1, h-1, 4, false)

    if not pts or #pts < 2 then
        gl.Color(C.muted[1], C.muted[2], C.muted[3], 0.25)
        gl.Text("— awaiting data —", cX + cW/2, cY + cH/2, 10, "c")
    else
        -- Y-axis labels
        for i = 0, 4 do
            local v    = mn + (r * i / 4)
            local yPos = cY + (cH * i / 4)
            gl.Color(C.muted[1], C.muted[2], C.muted[3], C.muted[4])
            local label = isPercent and fmtPct(v) or fmtNum(v)
            gl.Text(label, cX - 5, yPos - 4, 9, "ro")
        end
    end

    -- Chart title
    gl.Color(C.muted[1], C.muted[2], C.muted[3], C.muted[4])
    gl.Text(chart.icon .. "  " .. chart.label, PAD.left + 2, h - PAD.top - 10, 10, "o")

    gl.PopMatrix()
end

local function buildCard(card, value)
    gl.PushMatrix()
    gl.Translate(card.x, card.y, 0)
    gl.Scale(card.scale, card.scale, 1)

    gl.Color(C.bg[1], C.bg[2], C.bg[3], C.bg[4])
    drawRoundedRect(0, 0, CARD_WIDTH, CARD_HEIGHT, 4, true)
    gl.Color(C.border[1], C.border[2], C.border[3], C.border[4])
    gl.LineWidth(1)
    drawRoundedRect(0.5, 0.5, CARD_WIDTH-1, CARD_HEIGHT-1, 4, false)

    -- Coloured left accent bar
    local col = card.color
    gl.Color(col[1], col[2], col[3], 0.7)
    gl.BeginEnd(GL.QUADS, function()
        gl.Vertex(0, 4); gl.Vertex(3, 4)
        gl.Vertex(3, CARD_HEIGHT-4); gl.Vertex(0, CARD_HEIGHT-4)
    end)

    -- Label
    gl.Color(C.muted[1], C.muted[2], C.muted[3], C.muted[4])
    gl.Text(card.icon .. "  " .. card.label, 10, CARD_HEIGHT-18, 9, "o")

    -- Value
    gl.Color(col[1], col[2], col[3], 1.0)
    local vStr = card.isPercent and fmtPct(value) or fmtNum(value)
    gl.Text(vStr, CARD_WIDTH/2+5, 10, 20, "co")

    gl.PopMatrix()
end

local function rebuildChromeList()
    if chromeList then gl.DeleteList(chromeList) end

    local ptsBE = ringSample("buildEfficiency", RENDER_POINTS)
    local ptsBP = ringSample("buildPower",      RENDER_POINTS)

    local mnBE, _, rBE = nil, nil, nil
    if #ptsBE >= 2 then
        local mn, mx, r = computeRange(chartBE)
        if mn then mnBE = mn; rBE = r end
    end

    local mnBP, _, rBP = nil, nil, nil
    if #ptsBP >= 2 then
        local mn, mx, r = computeRange(chartBP)
        if mn then mnBP = mn; rBP = r end
    end

    chromeList = gl.CreateList(function()
        -- Edit-mode hint
        if chartsInteractive then
            gl.Color(C.gold[1], C.gold[2], C.gold[3], 0.55)
            gl.Text("EDIT MODE  |  drag to move  |  scroll to scale  |  right-click to toggle", vsx/2, 30, 11, "co")
        else
            gl.Color(C.muted[1], C.muted[2], C.muted[3], 0.35)
            gl.Text("F9: Toggle  |  /barbuild edit", vsx - 220, 30, 11, "o")
        end

        if chartBE.visible and chartBE.enabled then
            buildChrome(chartBE, ptsBE, mnBE or 0, rBE or 100, true)
        end
        if chartBP.visible and chartBP.enabled then
            buildChrome(chartBP, ptsBP, mnBP or 0, rBP or 1, false)
        end
        if cardBE.visible and cardBE.enabled then
            buildCard(cardBE, liveBuildEfficiency)
        end
        if cardBP.visible and cardBP.enabled then
            buildCard(cardBP, liveBuildPower)
        end
    end)

    chromeDirty = false
end

-- ── Lines: shader-rendered line + fill ────────────────────────────────────

local function rebuildLinesList()
    if linesList then gl.DeleteList(linesList) end
    local t = elapsedSecs()

    linesList = gl.CreateList(function()
        gl.Blending(true)
        gl.BlendFunc(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)

        local function drawChart(chart)
            if not (chart.visible and chart.enabled) then return end
            local pts = ringSample(chart.seriesKey, RENDER_POINTS)
            if #pts < 2 then return end
            local mn, mx, r = computeRange(chart)
            if not mn then return end

            -- Cache range for live grid drawing.
            if chart.id == "chart-build-efficiency" then
                rangeBE = { mn = mn, mx = mx, r = r }
            else
                rangeBP = { mn = mn, mx = mx, r = r }
            end

            local cX  = PAD.left
            local cY  = PAD.bottom
            local cW  = chart.width  - PAD.left - PAD.right
            local cH  = chart.height - PAD.top  - PAD.bottom
            local scl = chart.scale
            local col = { chart.color[1], chart.color[2], chart.color[3], 1.0 }
            local hw  = LINE_HALF_WIDTH  / scl
            local gr  = LINE_GLOW_RADIUS / scl

            gl.PushMatrix()
            gl.Translate(chart.x, chart.y, 0)
            gl.Scale(scl, scl, 1)

            -- Fill
            gl.BlendFunc(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
            shaderDrawFill(pts, cX, cY, cW, cH, mn, r, col, t)

            -- Line (additive glow)
            gl.BlendFunc(GL.SRC_ALPHA, GL.ONE)
            shaderDrawLine(pts, cX, cY, cW, cH, mn, r, col, hw, gr)

            -- Endpoint dot
            gl.BlendFunc(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
            local last = pts[#pts]
            if last and not (last ~= last) then
                local dotY = cY + ((last - mn) / r) * cH
                dotY = math.max(cY, math.min(cY + cH, dotY))
                gl.Color(col[1], col[2], col[3], 0.9)
                gl.PointSize(5)
                gl.BeginEnd(GL.POINTS, function() gl.Vertex(cX + cW, dotY) end)
            end

            -- Time axis
            local _, count = ringRange(chart.seriesKey)
            local windowSecs = count / GAME_FPS
            local nowSecs    = Spring.GetGameFrame() / GAME_FPS
            if windowSecs >= BASE_TICK_SECS then
                gl.BlendFunc(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
                drawTimeAxis(cX, cW, cY, windowSecs, nowSecs, 1.0)
            end

            gl.PopMatrix()
        end

        drawChart(chartBE)
        drawChart(chartBP)

        gl.Blending(false)
    end)

    linesDirty     = false
    linesLastRebuild = Spring.GetTimer()
end

-- ── Overlay: stall warnings, hover highlights ──────────────────────────────

local function rebuildOverlayList()
    if overlayList then gl.DeleteList(overlayList) end

    overlayList = gl.CreateList(function()
        -- Stall warning on card + chart
        if liveMetalStall > 0 then
            local sc = liveMetalStall == 2 and C.danger or C.gold
            gl.Color(sc[1], sc[2], sc[3], 1.0)
            -- On card
            if cardBE.visible and cardBE.enabled then
                gl.PushMatrix()
                gl.Translate(cardBE.x, cardBE.y, 0)
                gl.Scale(cardBE.scale, cardBE.scale, 1)
                gl.Text("⚠ STALL", CARD_WIDTH - 6, CARD_HEIGHT - 18, 9, "ro")
                gl.PopMatrix()
            end
            -- On chart
            if chartBE.visible and chartBE.enabled then
                gl.PushMatrix()
                gl.Translate(chartBE.x, chartBE.y, 0)
                gl.Scale(chartBE.scale, chartBE.scale, 1)
                gl.Text("⚠ STALL", chartBE.width - PAD.right - 2, chartBE.height - PAD.top - 10, 10, "ro")
                gl.PopMatrix()
            end
        end

        -- Hover highlight
        local function hoverHighlight(elem, w, h)
            if not elem.isHovered then return end
            gl.PushMatrix()
            gl.Translate(elem.x, elem.y, 0)
            gl.Scale(elem.scale, elem.scale, 1)
            gl.Color(C.borderHot[1], C.borderHot[2], C.borderHot[3], 0.8)
            gl.LineWidth(2.0)
            drawRoundedRect(0.5, 0.5, w-1, h-1, 4, false)
            gl.PopMatrix()
        end
        hoverHighlight(chartBE, chartBE.width,  chartBE.height)
        hoverHighlight(chartBP, chartBP.width,  chartBP.height)
        hoverHighlight(cardBE,  CARD_WIDTH,      CARD_HEIGHT)
        hoverHighlight(cardBP,  CARD_WIDTH,      CARD_HEIGHT)
    end)

    overlayDirty = false
end

-- ── Live grid (drawn every frame, outside display lists) ──────────────────

local function drawLiveGridLines()
    local t = elapsedSecs()

    local function drawGrid(chart, range)
        if not (chart.visible and chart.enabled) then return end
        local _, count = ringRange(chart.seriesKey)
        if count < 2 then return end

        local cX  = PAD.left
        local cY  = PAD.bottom
        local cW  = chart.width  - PAD.left - PAD.right
        local cH  = chart.height - PAD.top  - PAD.bottom

        gl.PushMatrix()
        gl.Translate(chart.x, chart.y, 0)
        gl.Scale(chart.scale, chart.scale, 1)

        for i = 0, 4 do
            local yPos = cY + (cH * i / 4)
            local gc   = (i == 0) and C.gridBase or C.grid
            shaderDrawGridLine(cX, yPos, cX + cW, yPos, cY, cH, gc, t)
        end

        gl.PopMatrix()
    end

    drawGrid(chartBE, rangeBE)
    drawGrid(chartBP, rangeBP)
end

-- ═══════════════════════════════════════════════════════════════════════════
--  MOUSE HELPERS
-- ═══════════════════════════════════════════════════════════════════════════

local function inRect(elem, mx, my, w, h)
    return mx >= elem.x and mx <= elem.x + w * elem.scale
       and my >= elem.y and my <= elem.y + h * elem.scale
end

local allElems = nil   -- populated after buildLayout

local function getAllElems()
    return {
        { elem = chartBE, w = chartBE.width,  h = chartBE.height,  kind = "chart" },
        { elem = chartBP, w = chartBP.width,  h = chartBP.height,  kind = "chart" },
        { elem = cardBE,  w = CARD_WIDTH,       h = CARD_HEIGHT,      kind = "card"  },
        { elem = cardBP,  w = CARD_WIDTH,       h = CARD_HEIGHT,      kind = "card"  },
    }
end

-- ═══════════════════════════════════════════════════════════════════════════
--  INITIALISE
-- ═══════════════════════════════════════════════════════════════════════════

function widget:Initialize()
    Spring.Echo("BAR Build Monitor v1.1: Initialize")
    vsx, vsy = Spring.GetViewGeometry()

    myTeamID    = Spring.GetMyTeamID()
    chartsReady = myTeamID ~= nil

    initRing()
    buildLayout()
    initShaders()
    loadConfig()

    widgetTimer = Spring.GetTimer()

    chromeDirty  = true
    linesDirty   = true
    overlayDirty = true

    -- ── Public API ────────────────────────────────────────────────────────
    WG.BarBuildMonitor = {
        version = "1.1",

        -- ── DATA EXPORT ────────────────────────────────────────────────────
        -- Returns a plain Lua table snapshot of the current ring buffers.
        -- The caller owns the returned table; it is a deep copy with no
        -- references back into this widget's state.
        -- Schema: { version, sampleIntervalSecs, totalSamples,
        --           buildEfficiency={...}, buildPower={...} }
        saveData = function()
            return saveData()
        end,

        -- ── DATA IMPORT / RENDER ───────────────────────────────────────────
        -- Accepts a table previously returned by saveData() (or any table
        -- conforming to the same schema) and replays it into the ring buffers
        -- before resuming live collection.
        -- Effect is deferred to the next GameFrame tick so it is safe to call
        -- from any context (DrawScreen, Update, another widget's callback…).
        renderData = function(snapshot)
            if type(snapshot) ~= "table" then
                Spring.Echo("BAR Build Monitor: renderData — argument must be a table")
                return
            end
            renderDataTable = snapshot
            renderPending   = true
        end,

        -- ── FILE-BASED REPLAY (legacy / convenience) ───────────────────────
        -- Replays the file-loaded snapshot (set at widget startup from config)
        -- up to `upToSecs` seconds from the first recorded sample.
        replayUpTo = function(upToSecs)
            replayPending  = true
            replayUpToSecs = upToSecs or 0
        end,

        -- Flush the current ring buffers to the config file on disk.
        saveSnapshot = function()
            saveConfig()
        end,

        -- ── LIVE STAT ACCESSORS ────────────────────────────────────────────
        getBuildEfficiency = function() return liveBuildEfficiency end,
        getBuildPower      = function() return liveBuildPower      end,
        getMetalStall      = function() return liveMetalStall      end,

        -- Raw downsampled series — useful for third-party overlays.
        getSamples = function(key, numPoints)
            return ringSample(key, numPoints or RENDER_POINTS)
        end,

        -- Seconds between samples (constant for the widget's lifetime).
        getSampleInterval = function() return sampleIntervalSecs end,

        -- Total samples pushed to the ring buffers since last reset.
        getTotalSamples = function() return totalSamplesPushed end,
    }

    Spring.Echo(string.format("BAR Build Monitor v1.1: Ready (teamID=%s)", tostring(myTeamID)))
end

-- ═══════════════════════════════════════════════════════════════════════════
--  GAME FRAME  (data collection)
-- ═══════════════════════════════════════════════════════════════════════════

function widget:GameFrame(n)
    -- Process a pending renderData() call from the API.
    -- Handled here (rather than directly in the API function) so that ring
    -- buffer mutations never happen mid-frame while DrawScreen may be running.
    if renderPending then
        renderPending   = false
        renderDataFromTable(renderDataTable)
        renderDataTable = nil
    end

    -- Process a pending replayUpTo() call (file-snapshot based).
    if replayPending then
        replayPending = false
        replaySnapshot(replayUpToSecs or 0)
    end

    if not chartsReady then
        -- Try once per second to acquire team ID.
        if n % GAME_FPS == 0 then
            myTeamID = Spring.GetMyTeamID()
            if myTeamID then
                chartsReady = true
                Spring.Echo("BAR Build Monitor: team acquired — teamID=" .. myTeamID)
            end
        end
        return
    end

    -- Sample build efficiency at the configured cadence.
    beTickCounter = beTickCounter + 1
    if beTickCounter >= BUILD_EFF_TICKS then
        beTickCounter = 0
        local eff, bp = sampleBuildEfficiency()
        pushEffSample(eff, bp)
        updateMetalStall()
        chromeDirty  = true   -- card values change
        overlayDirty = true
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
--  UPDATE (polls for team change if spectating)
-- ═══════════════════════════════════════════════════════════════════════════

function widget:Update(_dt)
    -- If the local team changes (e.g. spectator hop), refresh.
    local tid = Spring.GetLocalTeamID()
    if tid and tid ~= myTeamID then
        myTeamID    = tid
        chartsReady = true
        chromeDirty  = true
        linesDirty   = true
        overlayDirty = true
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
--  GAME START
-- ═══════════════════════════════════════════════════════════════════════════

function widget:GameStart()
    initRing()
    totalSamplesPushed  = 0
    beTickCounter       = 0
    beIndex             = 0
    beCount             = 0
    for i = 1, BUILD_EFF_WINDOW do beSamples[i] = 0 end
    liveBuildEfficiency = 0
    liveBuildPower      = 0
    liveMetalStall      = 0
    maxMetalCache       = {}
    widgetTimer         = Spring.GetTimer()
    chromeDirty  = true
    linesDirty   = true
    overlayDirty = true
    Spring.Echo("BAR Build Monitor: game started")
end

-- ═══════════════════════════════════════════════════════════════════════════
--  DRAW SCREEN
-- ═══════════════════════════════════════════════════════════════════════════

function widget:DrawScreen()
    if not widgetEnabled then return end

    if chromeDirty then rebuildChromeList() end

    -- Rate-limit line rebuilds.
    do
        local minInterval = 1.0 / math.max(1, math.min(60, MAX_CHART_FPS))
        local timeReady   = (linesLastRebuild == nil)
                         or (Spring.DiffTimers(Spring.GetTimer(), linesLastRebuild) >= minInterval)
        if timeReady and linesDirty then
            rebuildLinesList()
            overlayDirty = true
        end
    end

    if overlayDirty then rebuildOverlayList() end

    if chromeList  then gl.CallList(chromeList)  end
    drawLiveGridLines()
    if linesList   then gl.CallList(linesList)   end
    if overlayList then gl.CallList(overlayList) end
end

-- ═══════════════════════════════════════════════════════════════════════════
--  INPUT
-- ═══════════════════════════════════════════════════════════════════════════

function widget:KeyPress(key, _mods, _isRepeat)
    if key == Spring.GetKeyCode("f9") then
        widgetEnabled = not widgetEnabled
        Spring.Echo("BAR Build Monitor: " .. (widgetEnabled and "shown" or "hidden"))
        return true
    end
    return false
end

function widget:MousePress(mx, my, button)
    if not widgetEnabled or not chartsInteractive then return false end
    for _, rec in ipairs(getAllElems()) do
        if inRect(rec.elem, mx, my, rec.w, rec.h) then
            if button == 1 then
                rec.elem.isDragging = true
                rec.elem.dragStartX = mx - rec.elem.x
                rec.elem.dragStartY = my - rec.elem.y
                overlayDirty = true
                return true
            elseif button == 3 then
                rec.elem.enabled = not rec.elem.enabled
                chromeDirty  = true
                linesDirty   = true
                overlayDirty = true
                return true
            end
        end
    end
    return false
end

function widget:MouseRelease(_mx, _my, button)
    if not widgetEnabled or not chartsInteractive then return false end
    if button == 1 then
        for _, rec in ipairs(getAllElems()) do
            if rec.elem.isDragging then
                rec.elem.isDragging = false
                overlayDirty = true
                return true
            end
        end
    end
    return false
end

function widget:MouseMove(mx, my, _dx, _dy)
    if not widgetEnabled then return false end
    if chartsInteractive then
        for _, rec in ipairs(getAllElems()) do
            if rec.elem.isDragging then
                rec.elem.x = snapTo(mx - rec.elem.dragStartX)
                rec.elem.y = snapTo(my - rec.elem.dragStartY)
                chromeDirty  = true
                linesDirty   = true
                overlayDirty = true
                return true
            end
        end
    end

    local changed = false
    for _, rec in ipairs(getAllElems()) do
        local h = chartsInteractive and inRect(rec.elem, mx, my, rec.w, rec.h) or false
        if h ~= rec.elem.isHovered then changed = true end
        rec.elem.isHovered = h
    end
    if changed then overlayDirty = true end

    if not chartsInteractive then return false end
    for _, rec in ipairs(getAllElems()) do
        if rec.elem.isHovered then return true end
    end
    return false
end

function widget:MouseWheel(up, _value)
    if not widgetEnabled or not chartsInteractive then return false end
    local mx, my = Spring.GetMouseState()
    for _, rec in ipairs(getAllElems()) do
        if inRect(rec.elem, mx, my, rec.w, rec.h) then
            local s = rec.elem.scale
            rec.elem.scale = up and math.min(2.0, s + 0.1) or math.max(0.5, s - 0.1)
            chromeDirty  = true
            linesDirty   = true
            overlayDirty = true
            return true
        end
    end
    return false
end

function widget:ViewResize()
    local ox, oy = vsx, vsy
    vsx, vsy     = Spring.GetViewGeometry()
    local rx, ry = vsx/ox, vsy/oy
    for _, rec in ipairs(getAllElems()) do
        rec.elem.x = rec.elem.x * rx
        rec.elem.y = rec.elem.y * ry
    end
    chromeDirty  = true
    linesDirty   = true
    overlayDirty = true
end

-- ═══════════════════════════════════════════════════════════════════════════
--  TEXT COMMANDS
-- ═══════════════════════════════════════════════════════════════════════════

function widget:TextCommand(command)
    if command == "barbuild save" then
        saveConfig(); return true
    elseif command == "barbuild reset" then
        os.remove(CONFIG_FILE)
        Spring.Echo("BAR Build Monitor: config deleted — reload to restore defaults")
        return true
    elseif command == "barbuild edit" then
        chartsInteractive = not chartsInteractive
        chromeDirty  = true
        overlayDirty = true
        Spring.Echo("BAR Build Monitor: " .. (chartsInteractive and "EDIT mode ON" or "LOCKED"))
        return true
    elseif command == "barbuild debug" then
        Spring.Echo("=== BAR Build Monitor v1.1 Debug ===")
        Spring.Echo(string.format("widgetEnabled=%s  chartsReady=%s  interactive=%s",
            tostring(widgetEnabled), tostring(chartsReady), tostring(chartsInteractive)))
        Spring.Echo(string.format("myTeamID=%s  liveBE=%.1f%%  liveBP=%.0f  stall=%d",
            tostring(myTeamID), liveBuildEfficiency, liveBuildPower, liveMetalStall))
        local _, cntBE = ringRange("buildEfficiency")
        local _, cntBP = ringRange("buildPower")
        Spring.Echo(string.format("samples: BE=%d  BP=%d  total=%d  interval=%.2fs",
            cntBE, cntBP, totalSamplesPushed, sampleIntervalSecs))
        Spring.Echo(string.format("pending: replay=%s  render=%s  renderDataLoaded=%s",
            tostring(replayPending), tostring(renderPending), tostring(renderDataTable ~= nil)))
        Spring.Echo(string.format("shaders: line=%s  fill=%s  grid=%s",
            tostring(shaderLine~=nil), tostring(shaderFill~=nil), tostring(shaderGrid~=nil)))
        return true
    elseif command:sub(1, 14) == "barbuild replay" then
        local arg = tonumber(command:sub(16))
        if arg then
            replayPending  = true
            replayUpToSecs = arg
            Spring.Echo(string.format("BAR Build Monitor: replay queued up to %.1fs", arg))
        else
            Spring.Echo("Usage: /barbuild replay <seconds>")
        end
        return true
    end
    return false
end

-- ═══════════════════════════════════════════════════════════════════════════
--  SHUTDOWN
-- ═══════════════════════════════════════════════════════════════════════════

function widget:Shutdown()
    WG.BarBuildMonitor = nil
    saveConfig()
    freeLists()
    deleteShaders()
    Spring.Echo("BAR Build Monitor v1.1: Shutdown")
end
