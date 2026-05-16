-- regression_probe.lua — Windows FEMM 4.2 side of the macOS regression harness.
--
-- Run inside the Windows FEMM GUI via Lua console:  File → Open Lua Script…
-- or from a shell with:  femm.exe -lua-script=regression_probe.lua  (requires
-- the .fem to be in the same directory).
--
-- It mirrors libfemm_core/femm_cli_regression.cpp probe-for-probe and writes
-- report_windows.txt next to the .fem. tools/compare_reports.py diffs the two
-- reports.
--
-- Output format (matches the macOS side): `<key> <value>` with value formatted
-- %.10g. Same probe keys; missing on either side is flagged non-fatal.

--------------------------------------------------------------------------------
-- Config — the .fem we are probing. The file must sit in the same directory
-- as this script. Change the path if you point FEMM at a different fixture.
--------------------------------------------------------------------------------
FEM_PATH     = "Z:\\tutorial.fem"          -- absolute Windows path
REPORT_PATH  = "Z:\\report_windows.txt"    -- output on the shared drive
-- `Z:` is the conventional Windows drive letter for the VM's mapped share,
-- which on the host is /Users/linusmeiehofer/Documents/WindowsVM. Change
-- both paths if your share maps elsewhere.

--------------------------------------------------------------------------------
-- Probe set — keep IN SYNC with libfemm_core/femm_cli_regression.cpp
--------------------------------------------------------------------------------
local probe_xy = {
    { 0.00,  0.0  },
    { 0.25,  0.0  },
    { 0.40,  0.0  },
    { 0.00,  0.5  },
    { 0.25,  0.5  },
    { 0.00,  1.2  },
    { 1.00,  0.0  },
    { 2.00,  0.0  },
    { 0.00, -0.5  },
    { 0.25, -0.5  },
}

-- Maxwell-stress contours in inches. Closed contours are clockwise so FEMM's
-- 1e-6 left-normal sampling offset stays on the exterior air side.
local stress_contours = {
    { "coil_tight_cw", {
        { 0.35, -1.15 },
        { 0.35,  1.15 },
        { 1.65,  1.15 },
        { 1.65, -1.15 },
        { 0.35, -1.15 },
    } },
    { "coil_medium_cw", {
        { 0.15, -1.80 },
        { 0.15,  1.80 },
        { 2.20,  1.80 },
        { 2.20, -1.80 },
        { 0.15, -1.80 },
    } },
    { "coil_large_cw", {
        { 0.08, -2.60 },
        { 0.08,  2.60 },
        { 2.85,  2.60 },
        { 2.85, -2.60 },
        { 0.08, -2.60 },
    } },
    { "air_right_cw", {
        { 1.65, -0.75 },
        { 2.55, -0.75 },
        { 2.55,  0.75 },
        { 1.65,  0.75 },
        { 1.65, -0.75 },
    } },
    { "h_y0_open", {
        { 0.00, 0.00 },
        { 1.00, 0.00 },
    } },
    { "outer_y0_open", {
        { 1.65, 0.00 },
        { 2.65, 0.00 },
    } },
}

--------------------------------------------------------------------------------
-- Formatter. FEMM's Lua has no built-in %g with precision in write(), so we
-- snprintf-style via format().
--
-- NOTE: FEMM 4.2 ships Lua 4.0, which has NO `local function` syntax and NO
-- `table.getn`. Use plain `function` and manual length counters throughout.
--------------------------------------------------------------------------------
function fmt(v)
    -- Lua 4.0: format supports %g; %.10g is honored.
    return format("%.10g", v)
end

fp = openfile(REPORT_PATH, "w")
if fp == nil then
    error("Cannot open " .. REPORT_PATH .. " for writing.")
end
function kv(k, v) write(fp, k .. " " .. fmt(v) .. "\n") end
function comment(s) write(fp, "# " .. s .. "\n") end
function add_stress_contour(points)
    mo_clearcontour()
    for i = 1, getn(points) do
        mo_addcontour(points[i][1], points[i][2])
    end
end

comment("femm regression report (magnetics, axi, tutorial solenoid)")
comment("generator Windows FEMM 4.2 + regression_probe.lua")
comment("units: length=inches, A=Wb/m, B=T, energy=J")
comment("probe_format: <key> <value>  (value is %.10g)")

--------------------------------------------------------------------------------
-- Open the .fem and analyze
--------------------------------------------------------------------------------
open(FEM_PATH)
mi_saveas(FEM_PATH)          -- ensures the file is on disk at a known name
mi_analyze(1)                -- 1 = hide solver window
mi_loadsolution()            -- opens the post-processor on the result
mo_smooth("off")             -- compare raw element fields; mac C ABI is unsmoothed

--------------------------------------------------------------------------------
-- Mesh statistics
--------------------------------------------------------------------------------
kv("mesh/num_nodes", mo_numnodes())
kv("mesh/num_elements", mo_numelements())

--------------------------------------------------------------------------------
-- Point probes:  A (Wb/m), Bx, By (T), |B| (T)
--   mo_getpointvalues(x,y) returns:
--     A, B1=Bx, B2=By, c (conductivity), E, H1, H2, Je, Js, mu1, mu2, Pe, Ph, ff
--------------------------------------------------------------------------------
for i = 1, getn(probe_xy) do
    local px, py = probe_xy[i][1], probe_xy[i][2]
    local A, Bx, By = mo_getpointvalues(px, py)
    if A == nil then
        kv(format("point/miss/%g,%g", px, py), 1.0)
    else
        kv(format("point/A/%g,%g",  px, py), A)
        kv(format("point/Bx/%g,%g", px, py), Bx)
        kv(format("point/By/%g,%g", px, py), By)
        kv(format("point/|B|/%g,%g", px, py), sqrt(Bx*Bx + By*By))
    end
end

--------------------------------------------------------------------------------
-- Block integrals over the coil region only (the "18 AWG" label at x=0.75,y=0).
-- In the macOS side we filter by block_idx==2; on the Windows side we click-
-- select the coil's label point directly. (The coil's group is 1, not 1000 —
-- the 1000 in the .fem row is the turn count.)
--------------------------------------------------------------------------------
mo_clearblock()
mo_selectblock(0.75, 0.0)

-- Integral types (magnetics, Windows FEMM):
--   0 A·J   1 A   2 Energy   3 H·B/2 (??)   4 ohmic losses   5 block area
--   6 perim (??)    7 total current   8 ∫Bx   9 ∫By   10 block volume
kv("coil/area",      mo_blockintegral(5))
kv("coil/volume",    mo_blockintegral(10))
kv("coil/A_dot_J",   mo_blockintegral(0))
kv("coil/int_A",     mo_blockintegral(1))
kv("coil/energy",    mo_blockintegral(2))
kv("coil/current",   mo_blockintegral(7))
kv("coil/int_Bx",    mo_blockintegral(8))
kv("coil/int_By",    mo_blockintegral(9))

--------------------------------------------------------------------------------
-- Block integrals over the Air region (group 0, the open space).
-- We select by clicking in the representative air cell at (1.94, -0.07)
-- from the tutorial. That's cheaper than searching by block_idx.
--------------------------------------------------------------------------------
mo_clearblock()
mo_selectblock(1.94, -0.07)
kv("air/area",   mo_blockintegral(5))
kv("air/energy", mo_blockintegral(2))

--------------------------------------------------------------------------------
-- Global block integrals — "select everything". FEMM has no single-call
-- "select all", so we iterate block labels manually.
--------------------------------------------------------------------------------
mo_clearblock()
-- There are 9 block labels in the tutorial. Click-select each:
local label_points = {
    { 0.75, 0.0 },                    -- coil
    { 2.9920242, 0.42050158 },        -- u3 shell 1
    { 2.9455804, 0.84463161 },        -- u4 shell 2
    { 2.8385162, 1.26378886 },        -- u5
    { 2.6713515, 1.66924568 },        -- u6
    { 2.4458705, 2.05232901 },        -- u7
    { 2.1651155, 2.40460433 },        -- u8 (if present)
    { 1.8333539, 2.71805890 },        -- u9 (if present)
    { 1.94,      -0.07 },             -- air
}
for i = 1, getn(label_points) do
    mo_selectblock(label_points[i][1], label_points[i][2])
end
kv("total/energy", mo_blockintegral(2))
kv("total/volume", mo_blockintegral(10))

--------------------------------------------------------------------------------
-- Line integrals.
--------------------------------------------------------------------------------
mo_clearcontour()
mo_addcontour(0.0, 0.0)
mo_addcontour(1.0, 0.0)
-- Type 0: B·n → returns flux (Wb), avg B·n (T).  Type 1: H·t → MMF (A), avg H·t (A/m).
local flux, avg_Bn = mo_lineintegral(0)
kv("line/h_y0/flux",   flux)
kv("line/h_y0/avg_Bn", avg_Bn)
local mmf, _ = mo_lineintegral(1)
kv("line/h_y0/mmf", mmf)

mo_clearcontour()
mo_addcontour(0.0, -0.9)
mo_addcontour(0.0,  0.9)
local mmf_axis, _ = mo_lineintegral(1)
kv("line/axis/mmf", mmf_axis)
-- Type 2: contour length (m); second value is "swept area" for axi.
local len, _ = mo_lineintegral(2)
kv("line/axis/length", len)

--------------------------------------------------------------------------------
-- Maxwell stress force/torque line integrals.
--------------------------------------------------------------------------------
for i = 1, getn(stress_contours) do
    local name = stress_contours[i][1]
    local points = stress_contours[i][2]
    add_stress_contour(points)
    local Fr, Fz = mo_lineintegral(3)
    kv(format("force/%s/Fr", name), Fr)
    kv(format("force/%s/Fz", name), Fz)
    local T, _ = mo_lineintegral(4)
    kv(format("torque/%s/T", name), T)
end

--------------------------------------------------------------------------------
-- Reference: circuit properties (Windows only; we log for human inspection
-- but the macOS side does not produce these).
--------------------------------------------------------------------------------
local current, voltage, flux_linkage = mo_getcircuitproperties("Coil")
kv("ref/coil/circuit_current",     current)
kv("ref/coil/circuit_voltage_drop", voltage)
kv("ref/coil/flux_linkage",         flux_linkage)

closefile(fp)
messagebox("regression_probe.lua done — see " .. REPORT_PATH)
