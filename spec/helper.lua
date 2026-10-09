-- Test bootstrap and a minimal assertion runner.
--
-- Spec files run on KOReader's own LuaJIT, from KOReader's install folder,
-- through spec/run.sh, which also points KO_HOME at a throwaway data folder.
-- Each spec file is its own process, so modules a spec patches (the fake HTTP
-- server) never leak into another one.
--
--     local T = dofile(os.getenv("RSSREADER_REPO") .. "/spec/helper.lua")
--     T.describe("thing", function()
--         T.it("does something", function()
--             T.eq(actual, expected)
--         end)
--     end)
--     T.finish()

local REPO = assert(os.getenv("RSSREADER_REPO"), "run the specs through spec/run.sh")
local KO_HOME = assert(os.getenv("KO_HOME"), "run the specs through spec/run.sh")

-- The same start-up steps KOReader's reader.lua takes before any widget can
-- be built, minus the ones that need a real screen or event loop.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(KO_HOME .. "/settings.reader.lua")
local Device = require("device")
require("document/canvascontext"):init(Device)
require("ui/uimanager"):init()

package.path = REPO .. "/?.lua;" .. REPO .. "/spec/?.lua;" .. package.path

-- Never load the user's real rssreader_configuration.lua (it holds
-- credentials): Accounts:new() requires it, and a preload wins over the file.
local test_config = { accounts = {}, sanitizers = {}, features = {} }
package.preload["rssreader_configuration"] = function()
    return test_config
end

local T = {
    repo = REPO,
    ko_home = KO_HOME,
    config = test_config,
}

local MARK = "[spec] "
local results = { passed = 0, failed = 0 }
local prefix = {}

local function out(line)
    io.write(MARK, line, "\n")
    io.flush()
end

function T.describe(name, fn)
    table.insert(prefix, name)
    fn()
    table.remove(prefix)
end

function T.it(name, fn)
    local full = table.concat(prefix, " > ") .. (#prefix > 0 and " > " or "") .. name
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        results.passed = results.passed + 1
        out("ok    " .. full)
    else
        results.failed = results.failed + 1
        out("FAIL  " .. full)
        for line in tostring(err):gmatch("[^\n]+") do
            out("        " .. line)
        end
    end
end

local function describe_value(value)
    if type(value) == "string" then
        return string.format("%q", value)
    end
    return tostring(value)
end

local function deep_equal(a, b)
    if a == b then
        return true
    end
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    for k, v in pairs(a) do
        if not deep_equal(v, b[k]) then
            return false
        end
    end
    for k in pairs(b) do
        if a[k] == nil then
            return false
        end
    end
    return true
end

local function serialize(value, depth)
    depth = depth or 0
    if type(value) ~= "table" then
        return describe_value(value)
    end
    if depth > 3 then
        return "{...}"
    end
    local parts = {}
    for k, v in pairs(value) do
        parts[#parts + 1] = "[" .. describe_value(k) .. "]=" .. serialize(v, depth + 1)
    end
    table.sort(parts)
    return "{" .. table.concat(parts, ", ") .. "}"
end

function T.eq(actual, expected, label)
    if not deep_equal(actual, expected) then
        error(string.format("%sexpected %s, got %s", label and (label .. ": ") or "",
            serialize(expected), serialize(actual)), 2)
    end
end

function T.truthy(value, label)
    if not value then
        error((label or "expected a truthy value") .. ", got " .. describe_value(value), 2)
    end
end

function T.falsy(value, label)
    if value then
        error((label or "expected a falsy value") .. ", got " .. describe_value(value), 2)
    end
end

function T.contains(haystack, needle, label)
    if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
        error(string.format("%sexpected %s to contain %q", label and (label .. ": ") or "",
            describe_value(haystack), needle), 2)
    end
end

-- Marks the rest of this spec file skipped, with a reason, and exits cleanly.
function T.skip_file(reason)
    out("skip  " .. reason)
    out(string.format("done  passed=0 failed=0 skipped=1"))
    os.exit(0)
end

function T.finish()
    out(string.format("done  passed=%d failed=%d", results.passed, results.failed))
    os.exit(results.failed == 0 and 0 or 1)
end

return T
