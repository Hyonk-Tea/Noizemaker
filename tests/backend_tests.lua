package.path = "./?.lua;./?/init.lua;" .. package.path

local format = require("core.format")
local mods = require("core.mods")
local noize = require("core.noize")
local platform = require("core.platform")
local rebuild = require("core.rebuild")

local function read_all(path)
    local fh = assert(io.open(path, "rb"))
    local data = fh:read("*a")
    fh:close()
    return data
end

local function assert_true(value, message)
    if not value then
        error(message or "assertion failed", 2)
    end
end

local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s\nexpected: %s\nactual:   %s", message or "values differ", tostring(expected), tostring(actual)), 2)
    end
end

local function first_diff_index(a, b)
    local limit = math.min(#a, #b)
    for i = 1, limit do
        if string.byte(a, i) ~= string.byte(b, i) then
            return i
        end
    end
    if #a ~= #b then
        return limit + 1
    end
    return nil
end

local function assert_bytes_equal(actual, expected, label)
    local diff = first_diff_index(actual, expected)
    if diff ~= nil then
        local actual_byte = string.byte(actual, diff)
        local expected_byte = string.byte(expected, diff)
        error(string.format(
            "%s differs at byte %d (expected %s, got %s); lengths expected=%d actual=%d",
            label,
            diff - 1,
            expected_byte and string.format("0x%02X", expected_byte) or "<eof>",
            actual_byte and string.format("0x%02X", actual_byte) or "<eof>",
            #expected,
            #actual
        ), 2)
    end
end

local function find_entry(entries, name)
    for _, entry in ipairs(entries) do
        if entry.name == name then
            return entry
        end
    end
    error("missing entry: " .. name, 2)
end

local function step(code, gap)
    return format.Step.new(code, gap)
end

local function write_all(path, data)
    local fh = assert(io.open(path, "wb"))
    fh:write(data)
    fh:close()
end

local fixtures_dir = "./fixtures"
local vanilla_path = fixtures_dir .. "/r11_sh_VANILLABACKUP.bin"
local simple_expected_path = fixtures_dir .. "/r11_sh_simple_edit_expected.bin"
local ps007_expected_path = fixtures_dir .. "/r11_sh_ps007_expand_expected.bin"

local vanilla_buf = read_all(vanilla_path)
local vanilla_entries = format.parse(vanilla_buf)

local tests = {}

tests[#tests + 1] = function()
    assert_equal(#vanilla_entries, 72, "vanilla parse should find 72 entries")
    local ps007 = find_entry(vanilla_entries, "ps007")
    assert_equal(ps007.sc, 3, "ps007 should have 3 steps in vanilla")
    assert_equal(format.step_display_name(ps007.steps[1]), "UP", "ps007 first step display name")
    local prefix_len, ids = format.local_id_list_info(ps007)
    assert_equal(prefix_len, 4, "ps007 rescue prefix length")
    assert_equal(#ids, 2, "ps007 rescue ID count")
    assert_equal(ids[1], 0x77, "ps007 first rescue ID")
    assert_equal(ids[2], 0x52, "ps007 second rescue ID")
end

tests[#tests + 1] = function()
    local rebuilt = rebuild.apply_mods(vanilla_buf, vanilla_entries, {})
    assert_bytes_equal(rebuilt, vanilla_buf, "no-mod rebuild output")
end

tests[#tests + 1] = function()
    local mods = {
        pd001 = {
            step(2, 12),
            step(1, 0),
        },
    }
    local rebuilt = rebuild.apply_mods(vanilla_buf, vanilla_entries, mods)
    local expected = read_all(simple_expected_path)
    assert_bytes_equal(rebuilt, expected, "simple edit output")
end

tests[#tests + 1] = function()
    local mods = {
        ps007 = {
            {
                step(3, 24),
                step(2, 24),
                step(2, 24),
                step(6, 24),
                step(1, 0),
            },
            { 1, 2 },
            0,
        },
    }
    local rebuilt = rebuild.apply_mods(vanilla_buf, vanilla_entries, mods)
    local expected = read_all(ps007_expected_path)
    assert_bytes_equal(rebuilt, expected, "ps007 rescue expansion output")

    local parsed = format.parse(rebuilt)
    local ps007 = find_entry(parsed, "ps007")
    assert_equal(ps007.sc, 5, "expanded ps007 step count")
    local prefix_len, ids = format.local_id_list_info(ps007)
    assert_equal(prefix_len, 8, "expanded ps007 rescue prefix length")
    assert_equal(#ids, 4, "expanded ps007 rescue ID count")
    assert_equal(ids[1], 0x77, "expanded ps007 first rescue ID")
    assert_equal(ids[2], 0x52, "expanded ps007 second rescue ID")
    assert_equal(ids[3], 0x77, "expanded ps007 third rescue ID")
    assert_equal(ids[4], 0x52, "expanded ps007 fourth rescue ID")
end

tests[#tests + 1] = function()
    assert_equal(rebuild.encode_start_delay(3, 96), string.char(0x00, 0x60, 0x00), "odd step-count start delay encoding")
    assert_equal(rebuild.encode_start_delay(2, 48), string.char(0x30, 0x00), "even step-count start delay encoding")
end

tests[#tests + 1] = function()
    local rebuilt = rebuild.apply_mods(vanilla_buf, vanilla_entries, {
        pd001 = {
            timing = 20,
        },
    })
    local parsed = format.parse(rebuilt)
    local pd001 = find_entry(parsed, "pd001")
    assert_equal(pd001.timing, 20, "timing-only edit should rebuild with the new timing")
end

tests[#tests + 1] = function()
    local manifest, err = mods.parse_manifest([[
name: Example Mod Name
version: 1.0.0
description: Example manifest test.
changed_files:
  - r11_sh.bin
  - subdir/r11cap_e.bin
]])
    assert_true(manifest ~= nil, err)
    assert_equal(manifest.name, "Example Mod Name", "manifest name parse")
    assert_equal(manifest.version, "1.0.0", "manifest version parse")
    assert_equal(#manifest.changed_files, 2, "manifest changed_files count")
    assert_equal(manifest.changed_files[2], "subdir/r11cap_e.bin", "manifest changed_files path parse")
end

tests[#tests + 1] = function()
    local parsed, err = noize.parse("noize:https://gamebanana.com/mmdl/1687442,Mod,672910")
    assert_true(parsed ~= nil, err)
    assert_equal(parsed.archive_url, "https://gamebanana.com/mmdl/1687442", "noize archive url parse")
    assert_equal(parsed.item_type, "Mod", "noize item type parse")
    assert_equal(parsed.item_id, 672910, "noize item id parse")
    assert_equal(parsed.suggested_filename, "1687442.zip", "noize suggested filename from mmdl url")
end

tests[#tests + 1] = function()
    local parsed, err = noize.parse("noize://https://files.gamebanana.com/mods/rhythm_rebels.zip")
    assert_true(parsed ~= nil, err)
    assert_equal(parsed.archive_url, "https://files.gamebanana.com/mods/rhythm_rebels.zip", "noize archive-only url parse")
    assert_equal(parsed.item_type, nil, "noize archive-only item type")
    assert_equal(parsed.item_id, nil, "noize archive-only item id")
end

tests[#tests + 1] = function()
    local parsed, err = noize.parse("noize:not-a-url,Mod,123")
    assert_true(parsed == nil, "invalid noize URI should fail")
    assert_true(tostring(err):match("valid http/https archive URL") ~= nil, "invalid noize URI error text")
end

tests[#tests + 1] = function()
    local root = "./.build/test_list_files_recursive"
    assert_true(platform.remove_dir(root) or true, "cleanup should not fail")
    assert_true(platform.ensure_dir(root), "test root dir create")
    assert_true(platform.ensure_dir(root .. "/nested"), "nested dir create")
    write_all(root .. "/alpha.txt", "a")
    write_all(root .. "/nested/beta.txt", "b")

    local files = platform.list_files_recursive(root)
    assert_equal(#files, 2, "list_files_recursive should find 2 files")
    assert_equal(files[1], "alpha.txt", "list_files_recursive first relative file")
    assert_equal(files[2], "nested/beta.txt", "list_files_recursive nested relative file")

    platform.remove_dir(root)
end

for i = 1, #tests do
    tests[i]()
end

print(string.format("backend_tests.lua: PASS (%d tests)", #tests))
