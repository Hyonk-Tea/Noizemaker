package.path = "./?.lua;./?/init.lua;" .. package.path

local format = require("core.format")
local mods = require("core.mods")
local noize = require("core.noize")
local platform = require("core.platform")
local rebuild = require("core.rebuild")
local rules = require("core.rules")

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

local function current_dir()
    local pipe = assert(io.popen("cd"))
    local path = pipe:read("*l")
    pipe:close()
    return platform.normalize_slashes(path or ".")
end

local fixtures_dir = "./fixtures"
local vanilla_path = fixtures_dir .. "/r11_sh_VANILLABACKUP.bin"
local breaks_path = fixtures_dir .. "/r11_sh_breaks.bin"
local also_breaks_path = fixtures_dir .. "/r11_sh_alsobreaks.bin"
local simple_expected_path = fixtures_dir .. "/r11_sh_simple_edit_expected.bin"
local ps007_expected_path = fixtures_dir .. "/r11_sh_ps007_expand_expected.bin"
local r12_path = fixtures_dir .. "/R12_SH.BIN"
local r22_path = fixtures_dir .. "/R22_SH.BIN"
local r1_path = "D:/SteamLibrary/steamapps/common/Space Channel 5 Part 2/R1.BIN"

local vanilla_buf = read_all(vanilla_path)
local vanilla_entries = format.parse(vanilla_buf)
local breaks_buf = read_all(breaks_path)
local breaks_entries = format.parse(breaks_buf)
local also_breaks_buf = read_all(also_breaks_path)
local also_breaks_entries = format.parse(also_breaks_buf)
local r12_buf = read_all(r12_path)
local r12_entries = format.parse(r12_buf)
local r22_buf = read_all(r22_path)
local r22_entries = format.parse(r22_buf)
local r1_buf = read_all(r1_path)

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
    local ps007 = find_entry(vanilla_entries, "ps007")
    local rescue = rules.scan_rescue_event_records(ps007)
    assert_true(rescue ~= nil, "ps007 rescue scan should succeed")
    assert_equal(rescue.record_count, 2, "ps007 rescue event count")
    assert_equal(rescue.special_step_count, 2, "ps007 special-step count")
    assert_equal(rescue.archetype, "per_special_event", "ps007 rescue archetype")
    assert_equal(rescue.records[1].u16_1, 0x001B, "ps007 first rescue record field 1")
    assert_equal(rescue.records[1].u16_3, 0x001E, "ps007 first rescue record field 3")
    assert_equal(rescue.records[2].u16_3, 0x003C, "ps007 second rescue record field 3")
end

tests[#tests + 1] = function()
    local pd005 = find_entry(vanilla_entries, "pd005")
    assert_true(rules.detect_rescue_section(pd005) == nil, "pd005 triplet prefix should not be treated as expandable rescue ids")
    assert_true(rules.scan_rescue_event_records(pd005) == nil, "pd005 rescue-event scan should stay disabled without rescue ids")
end

tests[#tests + 1] = function()
    local ps002a = find_entry(r12_entries, "ps002a")
    assert_true(rules.detect_rescue_section(ps002a) == nil, "ps002a triplet prefix should not be treated as expandable rescue ids")
end

tests[#tests + 1] = function()
    local ps007 = find_entry(vanilla_entries, "ps007")
    local prefix = rules.scan_event_prefix(ps007)
    assert_true(prefix ~= nil, "ps007 event prefix should parse")
    assert_equal(prefix.prefix_len, 4, "ps007 event prefix length")
    assert_equal(#prefix.local_ids, 2, "ps007 event local ID count")
    assert_equal(prefix.local_ids[1], 0x77, "ps007 event first local ID")
    assert_equal(#prefix.declarations, 0, "ps007 event declaration count")
    assert_true(prefix.has_exact_local_id_prefix, "ps007 event prefix should be exact local IDs")
    assert_equal(prefix.shape, "L2", "ps007 prefix shape")
end

tests[#tests + 1] = function()
    local pd005 = find_entry(vanilla_entries, "pd005")
    local prefix = rules.scan_event_prefix(pd005)
    assert_true(prefix ~= nil, "pd005 event prefix should parse")
    assert_equal(prefix.prefix_len, 6, "pd005 event prefix length")
    assert_equal(#prefix.local_ids, 0, "pd005 should not expose local IDs in generic prefix scan")
    assert_equal(#prefix.declarations, 1, "pd005 declaration count")
    assert_equal(prefix.declarations[1].opcode, 0x0322, "pd005 declaration opcode")
    assert_equal(prefix.declarations[1].u16_2, 0x000E, "pd005 declaration second field")
    assert_equal(prefix.declarations[1].u16_3, 0x0000, "pd005 declaration third field")
    assert_equal(prefix.shape, "0322", "pd005 prefix shape")
    assert_equal(prefix.declarations[1].classification.kind, "id_only_declaration", "pd005 declaration kind")
    assert_equal(prefix.declarations[1].classification.id, 0x000E, "pd005 declaration classified ID")
    assert_equal(prefix.declarations[1].classification.param, 0x0000, "pd005 declaration classified param")
    assert_true(not prefix.declarations[1].classification.has_param, "pd005 declaration should not report a nonzero param")
    assert_equal(prefix.declarations[1].classification.param_hint, "zero", "pd005 declaration param hint")
end

tests[#tests + 1] = function()
    local pd005 = find_entry(vanilla_entries, "pd005")
    local scan = rules.scan_event_records(pd005)
    assert_true(scan ~= nil, "pd005 generic event-record scan should succeed")
    assert_equal(scan.record_count, 4, "pd005 generic event-record count")
    assert_equal(scan.special_step_count, 4, "pd005 generic special-step count")
    assert_equal(scan.prefix.declarations[1].opcode, 0x0322, "pd005 generic prefix declaration opcode")
    assert_equal(scan.records[1].u16_1, 0x001F, "pd005 first generic event field 1")
    assert_equal(scan.records[1].u16_3, 0x003C, "pd005 first generic event field 3")
    assert_equal(scan.records[1].tick_3, 48, "pd005 first generic event field 3 converted to ticks")
    assert_equal(scan.records[2].tick_3, 52, "pd005 second generic event field 3 converted to ticks")
    assert_equal(scan.records[4].tick_3, 72, "pd005 fourth generic event field 3 converted to ticks")
end

tests[#tests + 1] = function()
    local ps2001 = find_entry(vanilla_entries, "ps2001")
    local prefix = rules.scan_event_prefix(ps2001)
    assert_true(prefix ~= nil, "ps2001 event prefix should parse")
    assert_equal(#prefix.local_ids, 0, "ps2001 should not expose local IDs in generic prefix scan")
    assert_equal(#prefix.declarations, 3, "ps2001 declaration count")
    assert_equal(prefix.declarations[1].opcode, 0x0324, "ps2001 first declaration opcode")
    assert_equal(prefix.declarations[2].u16_3, 0x00BE, "ps2001 second declaration third field")
    assert_equal(prefix.declarations[3].u16_3, 0x017F, "ps2001 third declaration third field")
    assert_equal(prefix.shape, "0324+0324+0324", "ps2001 prefix shape")
    assert_equal(prefix.declarations[1].classification.kind, "id_and_param_declaration", "ps2001 declaration kind")
    assert_equal(prefix.declarations[1].classification.id, 0x0018, "ps2001 declaration classified ID")
    assert_equal(prefix.declarations[1].classification.param, 0x0000, "ps2001 first declaration classified param")
    assert_equal(prefix.declarations[1].classification.param_hint, "zero", "ps2001 first declaration param hint")
    assert_true(prefix.declarations[2].classification.has_param, "ps2001 second declaration should report a nonzero param")
    assert_equal(prefix.declarations[2].classification.param_hint, "position_like", "ps2001 second declaration param hint")
end

tests[#tests + 1] = function()
    local ps002a = find_entry(r12_entries, "ps002a")
    local prefix = rules.scan_event_prefix(ps002a)
    assert_true(prefix ~= nil, "ps002a event prefix should parse")
    assert_equal(#prefix.local_ids, 0, "ps002a should not expose local IDs in generic prefix scan")
    assert_equal(#prefix.declarations, 1, "ps002a declaration count")
    assert_equal(prefix.declarations[1].opcode, 0x0324, "ps002a declaration opcode")
    assert_equal(prefix.declarations[1].u16_2, 0x0018, "ps002a declaration second field")
    assert_equal(prefix.declarations[1].u16_3, 0x0000, "ps002a declaration third field")
    assert_equal(prefix.shape, "0324", "ps002a prefix shape")
    assert_equal(prefix.declarations[1].classification.kind, "id_and_param_declaration", "ps002a declaration kind")
end

tests[#tests + 1] = function()
    local ps007 = find_entry(vanilla_entries, "ps007")
    local scan = rules.scan_event_records(ps007)
    assert_true(scan ~= nil, "ps007 generic event-record scan should succeed")
    assert_equal(scan.records[1].tick_3, 24, "ps007 first generic event field 3 converted to ticks")
    assert_equal(scan.records[2].tick_3, 48, "ps007 second generic event field 3 converted to ticks")
    assert_equal(scan.records[1].tick_4, 12, "ps007 first generic event field 4 converted to ticks")
    assert_equal(scan.records[1].tick_5, 12, "ps007 first generic event field 5 converted to ticks")
    assert_equal(rules.event_units_to_ticks(120), 96, "generic event-unit conversion should match 5/4 scale")
end

tests[#tests + 1] = function()
    local ps003 = find_entry(vanilla_entries, "ps003")
    local tail = rules.scan_special_anim_tail(ps003)
    assert_true(tail ~= nil, "ps003 special-anim tail should parse")
    assert_equal(tail.shape, "chu_only", "ps003 special-anim tail shape")
    assert_true(tail.chu_only_synth_ok, "ps003 should be synthesizable in chu-only mode")
    assert_equal(#tail.prefix_tokens, 3, "ps003 FE token count")
    assert_equal(#tail.blocks, 3, "ps003 special-anim block count")
    assert_equal(tail.blocks[1].index, 1, "ps003 first block index")
    assert_equal(tail.blocks[3].index, 3, "ps003 third block index")
    local rebuilt_tail, err = rules.synthesize_chu_only_special_anim_tail(ps003, ps003:as_step_list())
    assert_true(rebuilt_tail ~= nil, err)
    assert_equal(rebuilt_tail, ps003.rest_body, "ps003 synthesized chu-only tail should round-trip")
end

tests[#tests + 1] = function()
    local ps006 = find_entry(vanilla_entries, "ps006")
    local tail = rules.scan_special_anim_tail(ps006)
    assert_true(tail ~= nil, "ps006 special-anim tail should parse")
    assert_equal(tail.shape, "chu_only", "ps006 special-anim tail shape")
    assert_true(tail.chu_only_synth_ok, "ps006 should be synthesizable in chu-only mode")
    assert_equal(tail.prefix_tokens[1], 0x00FE, "ps006 first FE token")
    assert_equal(tail.prefix_tokens[2], 0xFFFF, "ps006 separator token")
    assert_equal(tail.prefix_tokens[3], 0x00FE, "ps006 second FE token")
    local rebuilt_tail, err = rules.synthesize_chu_only_special_anim_tail(ps006, ps006:as_step_list())
    assert_true(rebuilt_tail ~= nil, err)
    assert_equal(rebuilt_tail, ps006.rest_body, "ps006 synthesized chu-only tail should round-trip")
end

tests[#tests + 1] = function()
    local ps001 = find_entry(vanilla_entries, "ps001")
    local new_steps = {
        step(format.INV.UP, 12),
        step(format.INV.CHU, 12),
        step(format.INV.CHU, 0),
    }
    local rebuilt_tail, err = rules.synthesize_chu_only_special_anim_tail(ps001, new_steps)
    assert_true(rebuilt_tail ~= nil, err)
    assert_equal(
        rebuilt_tail,
        "\254\000\254\000"
            .. "\067\002\001\000\042\003\000\000\005\000\020\002\016\065"
            .. "\067\002\002\000\042\003\000\000\005\000\020\002\016\065"
            .. "\000\001",
        "ps001 synthesized expanded chu-only tail"
    )
end

tests[#tests + 1] = function()
    local ps011 = find_entry(vanilla_entries, "ps011")
    local tail = rules.scan_special_anim_tail(ps011)
    assert_true(tail ~= nil, "ps011 special-anim tail should parse")
    assert_equal(tail.shape, "generic", "ps011 mixed CHU/HEY tail should stay generic")
    local rebuilt_tail = rules.synthesize_chu_only_special_anim_tail(ps011, ps011:as_step_list())
    assert_true(rebuilt_tail == nil, "ps011 should not be accepted by the chu-only synthesizer")
end

tests[#tests + 1] = function()
    local ps011 = find_entry(vanilla_entries, "ps011")
    local stream = rules.scan_special_event_stream(ps011)
    assert_true(stream ~= nil, "ps011 special-event stream should parse")
    assert_equal(stream.assignment_style, "separator_grouped_single_word", "ps011 assignment style")
    assert_equal(stream.family_style, "separator_grouped_single_word", "ps011 family style")
    assert_equal(#stream.token_groups, 2, "ps011 token-group count")
    assert_equal(stream.token_groups[1].words[1].value, 0x00FE, "ps011 first token group word")
    assert_equal(stream.token_groups[2].words[1].value, 0x007C, "ps011 second token group word")
    assert_equal(#stream.events, 2, "ps011 special-event count")
    assert_equal(stream.events[1].visible_name, "CHU", "ps011 first visible event")
    assert_equal(stream.events[1].encoded_kind, "chu_event", "ps011 first encoded kind")
    assert_equal(#stream.events[1].token_words, 1, "ps011 first token-word count")
    assert_equal(stream.events[1].token_words[1].value, 0x00FE, "ps011 CHU token")
    assert_equal(stream.events[1].block_kind, "single_43", "ps011 CHU block kind")
    assert_equal(stream.events[2].visible_name, "HEY", "ps011 second visible event")
    assert_equal(stream.events[2].encoded_kind, "hey_event", "ps011 second encoded kind")
    assert_equal(#stream.events[2].token_words, 1, "ps011 HEY token-word count")
    assert_equal(stream.events[2].token_words[1].value, 0x007C, "ps011 HEY token")
    assert_equal(stream.events[2].block_kind, "43_44_pair", "ps011 HEY block kind")
    assert_equal(#stream.prefix_declarations, 0, "ps011 prefix declaration count")
end

tests[#tests + 1] = function()
    local ps007 = find_entry(vanilla_entries, "ps007")
    local stream = rules.scan_special_event_stream(ps007)
    assert_true(stream ~= nil, "ps007 special-event stream should parse")
    assert_equal(stream.assignment_style, "sequential_single_word", "ps007 assignment style")
    assert_equal(stream.family_style, "sequential_single_word+prefix_4f07", "ps007 family style")
    assert_equal(#stream.prefix_event_records, 2, "ps007 prefix event-record count")
    assert_equal(#stream.token_groups, 1, "ps007 raw token-group count")
    assert_equal(stream.token_groups[1].words[1].value, 0x0077, "ps007 first raw token word")
    assert_equal(stream.token_groups[1].words[2].value, 0x0052, "ps007 second raw token word")
    assert_equal(#stream.events, 2, "ps007 special-event count")
    assert_equal(stream.events[1].visible_name, "HEY", "ps007 first visible event")
    assert_equal(stream.events[1].encoded_kind, "hey_event", "ps007 first encoded kind")
    assert_equal(stream.events[1].token_words[1].value, 0x0077, "ps007 first HEY token")
    assert_equal(stream.events[2].token_words[1].value, 0x0052, "ps007 second HEY token")
end

tests[#tests + 1] = function()
    local ps011 = find_entry(r22_entries, "ps011")
    local edited_steps = {
        step(format.INV.UP, 12),
        step(format.INV.LEFT, 12),
        step(format.INV.HEY, 12),
        step(format.INV.HEY, 0),
    }
    local result = rules.validate_mod(ps011, edited_steps)
    assert_true(not result.ok, "ps011 unsupported special-tail edit should fail validation")
    assert_true(
        tostring(result.errors[1] or ""):match("hidden special%-event data") ~= nil,
        "ps011 unsupported special-tail failure text"
    )
end

tests[#tests + 1] = function()
    local ps001 = find_entry(vanilla_entries, "ps001")
    local ps002 = find_entry(vanilla_entries, "ps002")
    local ps003 = find_entry(vanilla_entries, "ps003")
    local ps001_breaks = find_entry(also_breaks_entries, "ps001")
    local ps002_breaks = find_entry(also_breaks_entries, "ps002")
    local ps003_breaks = find_entry(also_breaks_entries, "ps003")

    assert_true(rules.validate_mod(ps001, ps001_breaks:as_step_list()).ok, "ps001 chu-only edit should validate")
    assert_true(rules.validate_mod(ps002, ps002_breaks:as_step_list()).ok, "ps002 chu-only edit should validate")
    assert_true(rules.validate_mod(ps003, ps003_breaks:as_step_list()).ok, "ps003 chu-only edit should validate")

    local rebuilt = rebuild.apply_mods(vanilla_buf, vanilla_entries, {
        ps001 = { ps001_breaks:as_step_list() },
        ps002 = { ps002_breaks:as_step_list() },
        ps003 = { ps003_breaks:as_step_list() },
    })
    local reparsed = format.parse(rebuilt)
    local rebuilt_ps001 = find_entry(reparsed, "ps001")
    local rebuilt_ps002 = find_entry(reparsed, "ps002")
    local rebuilt_ps003 = find_entry(reparsed, "ps003")

    local scan001 = rules.scan_special_anim_tail(rebuilt_ps001)
    local scan002 = rules.scan_special_anim_tail(rebuilt_ps002)
    local scan003 = rules.scan_special_anim_tail(rebuilt_ps003)

    assert_equal(#rebuilt_ps001.rest_body, 34, "ps001 rebuilt chu-only tail length")
    assert_equal(#rebuilt_ps002.rest_body, 50, "ps002 rebuilt chu-only tail length")
    assert_equal(#rebuilt_ps003.rest_body, 82, "ps003 rebuilt chu-only tail length")

    assert_equal(#scan001.blocks, 2, "ps001 rebuilt block count")
    assert_equal(#scan002.blocks, 3, "ps002 rebuilt block count")
    assert_equal(#scan003.blocks, 5, "ps003 rebuilt block count")

    assert_equal(scan001.blocks[1].index, 1, "ps001 rebuilt first block index")
    assert_equal(scan001.blocks[2].index, 2, "ps001 rebuilt second block index")
    assert_equal(scan002.blocks[3].index, 3, "ps002 rebuilt third block index")
    assert_equal(scan003.blocks[5].index, 5, "ps003 rebuilt fifth block index")
end

tests[#tests + 1] = function()
    local ps011 = find_entry(vanilla_entries, "ps011")
    local edited_steps = {
        step(format.INV.LEFT, 12),
        step(format.INV.CHU, 12),
        step(format.INV.UP, 12),
        step(format.INV.HEY, 12),
        step(format.INV.HEY, 0),
    }

    local result = rules.validate_mod(ps011, edited_steps)
    assert_true(result.ok, "ps011 mixed r11 edit should validate")

    local rebuilt = rebuild.apply_mods(vanilla_buf, vanilla_entries, {
        ps011 = { edited_steps },
    })
    local reparsed = format.parse(rebuilt)
    local rebuilt_ps011 = find_entry(reparsed, "ps011")
    local stream = rules.scan_special_event_stream(rebuilt_ps011)

    assert_equal(#stream.events, 3, "ps011 rebuilt event count")
    assert_equal(stream.events[1].visible_name, "CHU", "ps011 rebuilt first event")
    assert_equal(stream.events[1].token_words[1].value, 0x00FE, "ps011 rebuilt CHU token")
    assert_equal(stream.events[2].visible_name, "HEY", "ps011 rebuilt second event")
    assert_equal(stream.events[2].token_words[1].value, 0x007C, "ps011 rebuilt preserved tourist handle")
    assert_equal(stream.events[3].visible_name, "HEY", "ps011 rebuilt third event")
    assert_equal(stream.events[3].token_words[1].value, 0x007C, "ps011 rebuilt new HEY defaults to tourist")
end

tests[#tests + 1] = function()
    local ps007 = find_entry(vanilla_entries, "ps007")
    local edited_steps = {
        step(format.INV.UP, 24),
        step(format.INV.HEY, 24),
        step(format.INV.HEY, 24),
        step(format.INV.HEY, 0),
    }

    local result = rules.validate_mod(ps007, edited_steps)
    assert_true(result.ok, "ps007 HEY expansion should validate")

    local rebuilt = rebuild.apply_mods(vanilla_buf, vanilla_entries, {
        ps007 = { edited_steps },
    })
    local reparsed = format.parse(rebuilt)
    local rebuilt_ps007 = find_entry(reparsed, "ps007")
    local stream = rules.scan_special_event_stream(rebuilt_ps007)

    assert_equal(#stream.prefix_event_records, 3, "ps007 rebuilt prefix_4f07 count")
    assert_equal(stream.prefix_event_records[3].u16_3, 90, "ps007 rebuilt third prefix timing")
    assert_equal(stream.events[1].token_words[1].value, 0x0077, "ps007 rebuilt preserved first handle")
    assert_equal(stream.events[2].token_words[1].value, 0x0052, "ps007 rebuilt preserved second handle")
    assert_equal(stream.events[3].token_words[1].value, 0x007C, "ps007 rebuilt new HEY defaults to tourist")
end

tests[#tests + 1] = function()
    local ps008 = find_entry(vanilla_entries, "ps008")
    local edited_steps = {
        step(format.INV.RIGHT, 24),
        step(format.INV.CHU, 24),
        step(format.INV.HEY, 24),
        step(format.INV.HEY, 0),
    }

    local result = rules.validate_mod(ps008, edited_steps)
    assert_true(result.ok, "ps008 CHU/HEY remap should validate")

    local rebuilt = rebuild.apply_mods(vanilla_buf, vanilla_entries, {
        ps008 = { edited_steps },
    })
    local reparsed = format.parse(rebuilt)
    local rebuilt_ps008 = find_entry(reparsed, "ps008")
    local stream = rules.scan_special_event_stream(rebuilt_ps008)

    assert_equal(#stream.events, 3, "ps008 rebuilt event count")
    assert_equal(stream.events[1].visible_name, "CHU", "ps008 rebuilt first event")
    assert_equal(stream.events[1].token_words[1].value, 0x00FE, "ps008 rebuilt CHU token")
    assert_equal(stream.events[2].token_words[1].value, 0x0079, "ps008 rebuilt preserved second HEY handle")
    assert_equal(stream.events[3].token_words[1].value, 0x007C, "ps008 rebuilt new HEY defaults to tourist")
end

tests[#tests + 1] = function()
    local ps005 = find_entry(r22_entries, "ps005")
    local stream = rules.scan_special_event_stream(ps005)
    assert_true(stream ~= nil, "R22 ps005 special-event stream should parse")
    assert_equal(stream.assignment_style, "separator_grouped_single_word", "R22 ps005 assignment style")
    assert_equal(stream.family_style, "separator_grouped_single_word+decl", "R22 ps005 family style")
    assert_equal(#stream.token_groups, 3, "R22 ps005 token-group count")
    assert_equal(#stream.events, 3, "R22 ps005 special-event count")
    assert_equal(stream.events[1].visible_name, "HEY", "R22 ps005 first visible event")
    assert_equal(stream.events[1].encoded_kind, "hey_event", "R22 ps005 first encoded kind")
    assert_equal(stream.events[1].token_words[1].value, 0x00C4, "R22 ps005 first token")
    assert_equal(stream.events[2].visible_name, "CHU", "R22 ps005 second visible event")
    assert_equal(stream.events[2].encoded_kind, "chu_event", "R22 ps005 second encoded kind")
    assert_equal(stream.events[2].token_words[1].value, 0x00FE, "R22 ps005 CHU token")
    assert_equal(stream.events[3].visible_name, "HEY", "R22 ps005 third visible event")
    assert_equal(stream.events[3].encoded_kind, "hey_event", "R22 ps005 third encoded kind")
    assert_equal(stream.events[3].token_words[1].value, 0x00C4, "R22 ps005 final HEY token")
    assert_equal(#stream.prefix_declarations, 1, "R22 ps005 declaration count")
    assert_equal(stream.prefix_declarations[1].opcode, 0x0323, "R22 ps005 declaration opcode")
    assert_equal(stream.prefix_declarations[1].classification.kind, "special_tail_declaration", "R22 ps005 declaration kind")
end

tests[#tests + 1] = function()
    local ps011 = find_entry(r22_entries, "ps011")
    local stream = rules.scan_special_event_stream(ps011)
    assert_true(stream ~= nil, "R22 ps011 special-event stream should parse")
    assert_equal(stream.assignment_style, "separator_grouped_multi_word", "R22 ps011 assignment style")
    assert_equal(stream.family_style, "separator_grouped_multi_word", "R22 ps011 family style")
    assert_equal(#stream.token_groups, 1, "R22 ps011 token-group count")
    assert_equal(#stream.events, 1, "R22 ps011 special-event count")
    assert_equal(stream.events[1].visible_name, "HEY", "R22 ps011 visible event")
    assert_equal(stream.events[1].encoded_kind, "hey_event", "R22 ps011 encoded kind")
    assert_equal(#stream.events[1].token_words, 2, "R22 ps011 HEY token-word count")
    assert_equal(stream.events[1].token_words[1].value, 0x0065, "R22 ps011 first token")
    assert_equal(stream.events[1].token_words[2].value, 0x0066, "R22 ps011 second token")
    assert_equal(stream.events[1].block_kind, "43_44_pair", "R22 ps011 block kind")
end

tests[#tests + 1] = function()
    local ps009 = find_entry(r22_entries, "ps009")
    local stream = rules.scan_special_event_stream(ps009)
    assert_true(stream ~= nil, "R22 ps009 special-event stream should parse")
    assert_equal(stream.assignment_style, "separator_grouped_multi_word", "R22 ps009 assignment style")
    assert_equal(stream.family_style, "separator_grouped_multi_word+decl", "R22 ps009 family style")
    assert_equal(#stream.token_groups, 1, "R22 ps009 token-group count")
    assert_equal(#stream.events, 1, "R22 ps009 special-event count")
    assert_equal(stream.events[1].visible_name, "CHU", "R22 ps009 visible event")
    assert_equal(stream.events[1].encoded_kind, "chu_event", "R22 ps009 encoded kind")
    assert_equal(#stream.events[1].token_words, 2, "R22 ps009 CHU token-word count")
    assert_equal(stream.events[1].token_words[1].value, 0x00FE, "R22 ps009 first CHU token")
    assert_equal(stream.events[1].token_words[2].value, 0x00FE, "R22 ps009 second CHU token")
    assert_equal(#stream.prefix_declarations, 1, "R22 ps009 declaration count")
    assert_equal(stream.prefix_declarations[1].opcode, 0x0323, "R22 ps009 declaration opcode")
end

tests[#tests + 1] = function()
    local runs = rules.scan_0325_handle_record_runs(vanilla_buf)
    assert_true(#runs >= 1, "r11_sh should contain at least one 0325 handle-record run")

    local found = nil
    for i = 1, #runs do
        local handles = {}
        for _, handle_id in ipairs(runs[i].handle_ids) do
            handles[handle_id] = true
        end
        if handles[0x0077] and handles[0x0052] and handles[0x007C] then
            found = runs[i]
            break
        end
    end

    assert_true(found ~= nil, "r11_sh should expose the special-handle run containing 0077/0052/007C")
    assert_equal(found.records[1].handle_id, 0x0101, "r11_sh special-handle run first record handle")
    assert_equal(found.records[1].opcode, 0x0325, "r11_sh special-handle run opcode")
    assert_equal(found.records[#found.records].handle_id, 0x007C, "r11_sh special-handle run final record handle")
end

tests[#tests + 1] = function()
    local ps007 = find_entry(vanilla_entries, "ps007")
    local usage = rules.scan_special_handle_usage(ps007)
    assert_true(usage ~= nil, "ps007 special-handle usage should parse")
    assert_equal(#usage.handle_ids, 2, "ps007 unique special-handle count")
    assert_equal(usage.handle_ids[1], 0x0052, "ps007 sorted special handle 1")
    assert_equal(usage.handle_ids[2], 0x0077, "ps007 sorted special handle 2")
    assert_equal(usage.events[1].handle_ids[1], 0x0077, "ps007 first event handle")
    assert_equal(usage.events[2].handle_ids[1], 0x0052, "ps007 second event handle")

    local matches = rules.find_0325_handle_records(vanilla_buf, usage.handle_ids)
    assert_equal(#matches, 2, "ps007 should match two 0325 catalog records")
    assert_equal(matches[1].record.handle_id, 0x0077, "ps007 first matched 0325 handle")
    assert_equal(matches[2].record.handle_id, 0x0052, "ps007 second matched 0325 handle")
end

tests[#tests + 1] = function()
    local ps011 = find_entry(vanilla_entries, "ps011")
    local usage = rules.scan_special_handle_usage(ps011)
    assert_true(usage ~= nil, "ps011 special-handle usage should parse")
    assert_equal(#usage.handle_ids, 1, "ps011 unique special-handle count")
    assert_equal(usage.handle_ids[1], 0x007C, "ps011 HEY special handle")
    assert_equal(#usage.events[1].handle_ids, 0, "ps011 CHU event should not expose local handles")
    assert_equal(usage.events[2].handle_ids[1], 0x007C, "ps011 HEY event handle")

    local matches = rules.find_0325_handle_records(vanilla_buf, usage.handle_ids)
    assert_equal(#matches, 1, "ps011 should match one 0325 catalog record")
    assert_equal(matches[1].record.handle_id, 0x007C, "ps011 matched 0325 handle")
end

tests[#tests + 1] = function()
    local ps007 = find_entry(vanilla_entries, "ps007")
    local handle_map = rules.build_special_handle_map(ps007, vanilla_buf, r1_buf)
    assert_true(handle_map ~= nil, "ps007 special-handle map should build")
    assert_equal(#handle_map.handles, 2, "ps007 special-handle map handle count")

    local grandma = handle_map.by_handle[0x0077]
    local tourist = handle_map.by_handle[0x0052]
    assert_true(grandma ~= nil, "ps007 grandma handle map entry")
    assert_true(tourist ~= nil, "ps007 tourist handle map entry")

    assert_equal(#grandma.events, 1, "ps007 grandma event count")
    assert_equal(grandma.events[1].visible_name, "HEY", "ps007 grandma event type")
    assert_equal(#grandma.chart_records, 1, "ps007 grandma chart catalog matches")
    assert_equal(grandma.chart_records[1].record.offset, 0x300, "ps007 grandma chart record offset")
    assert_equal(#grandma.scene_records, 2, "ps007 grandma scene-list matches")

    assert_equal(#tourist.events, 1, "ps007 tourist event count")
    assert_equal(#tourist.chart_records, 1, "ps007 tourist chart catalog matches")
    assert_equal(tourist.chart_records[1].record.offset, 0x338, "ps007 tourist chart record offset")
    assert_equal(#tourist.scene_records, 1, "ps007 tourist scene-list matches")
end

tests[#tests + 1] = function()
    local ps007 = find_entry(vanilla_entries, "ps007")
    local annotation = rules.annotate_special_event_tokens(ps007, vanilla_buf, r1_buf)
    assert_true(annotation ~= nil, "ps007 token annotation should build")
    assert_equal(annotation.by_value[0x0077].classification, "catalog_and_scene_handle", "ps007 0077 token classification")
    assert_equal(annotation.by_value[0x0052].classification, "catalog_and_scene_handle", "ps007 0052 token classification")
end

tests[#tests + 1] = function()
    local runs = rules.scan_0325_handle_record_runs(r22_buf)
    assert_true(#runs >= 1, "R22_SH should contain at least one 0325 handle-record run")

    local found = nil
    for i = 1, #runs do
        local handles = {}
        for _, handle_id in ipairs(runs[i].handle_ids) do
            handles[handle_id] = true
        end
        if handles[0x005D] and handles[0x0064] and handles[0x0067] then
            found = runs[i]
            break
        end
    end

    assert_true(found ~= nil, "R22_SH should expose the special-handle run containing 005D/0064/0067")
    assert_equal(found.records[1].handle_id, 0x005E, "R22 special-handle run first record handle")
    assert_equal(found.records[2].handle_id, 0x005D, "R22 special-handle run second record handle")
    assert_equal(found.records[#found.records].handle_id, 0x0067, "R22 special-handle run final record handle")
end

tests[#tests + 1] = function()
    local function pack_u32(value)
        local b0 = value % 256
        local b1 = math.floor(value / 256) % 256
        local b2 = math.floor(value / 65536) % 256
        local b3 = math.floor(value / 16777216) % 256
        return string.char(b0, b1, b2, b3)
    end

    local buf = table.concat({
        pack_u32(0x0047), pack_u32(1),
        pack_u32(0x0077), pack_u32(1),
        pack_u32(0x0048), pack_u32(1),
        pack_u32(0x0000), pack_u32(0x0000),
    })
    local runs = rules.scan_handle_flag_lists(buf)
    assert_equal(#runs, 1, "synthetic handle-flag list should produce one run")
    assert_equal(runs[1].count, 3, "synthetic handle-flag list count")
    assert_equal(runs[1].records[1].handle_id, 0x0047, "synthetic handle-flag first handle")
    assert_equal(runs[1].records[2].flag, 1, "synthetic handle-flag second flag")
    assert_equal(runs[1].records[3].handle_id, 0x0048, "synthetic handle-flag third handle")
end

tests[#tests + 1] = function()
    local ps012 = find_entry(r22_entries, "ps012")
    local r2_buf = read_all("D:/SteamLibrary/steamapps/common/Space Channel 5 Part 2/R2.BIN")
    local annotation = rules.annotate_special_event_tokens(ps012, r22_buf, r2_buf)
    assert_true(annotation ~= nil, "R22 ps012 token annotation should build")
    assert_equal(annotation.by_value[0x00C4].classification, "unresolved_token", "R22 ps012 00C4 token classification")
    assert_equal(annotation.by_value[0x0067].classification, "catalog_and_scene_handle", "R22 ps012 0067 token classification")
end

tests[#tests + 1] = function()
    assert_equal(rules.prefix_shape({ 0xFD, 0xFD }, { { opcode = 0x0322 } }), "L2+0322", "mixed local-ID and declaration shape helper")
end

tests[#tests + 1] = function()
    local decl_0322 = rules.classify_declaration(0x0322, 0x0010, 0x0000)
    assert_equal(decl_0322.kind, "id_only_declaration", "0322 helper declaration kind")
    assert_equal(decl_0322.id, 0x0010, "0322 helper declaration ID")
    assert_true(not decl_0322.has_param, "0322 helper should not report a nonzero param")

    local decl_0324 = rules.classify_declaration(0x0324, 0x0014, 0x0060)
    assert_equal(decl_0324.kind, "id_and_param_declaration", "0324 helper declaration kind")
    assert_equal(decl_0324.id, 0x0014, "0324 helper declaration ID")
    assert_equal(decl_0324.param, 0x0060, "0324 helper declaration param")
    assert_true(decl_0324.has_param, "0324 helper should report a nonzero param")
    assert_equal(decl_0324.param_hint, "position_like", "0324 helper declaration param hint")
end

tests[#tests + 1] = function()
    local pd005 = find_entry(vanilla_entries, "pd005")
    local pd005_breaks = find_entry(breaks_entries, "pd005")
    local rebuilt = rebuild.apply_mods(vanilla_buf, vanilla_entries, {
        pd005 = {
            pd005_breaks:as_step_list(),
        },
    })
    local reparsed = format.parse(rebuilt)
    local rebuilt_pd005 = find_entry(reparsed, "pd005")
    assert_true(rules.detect_rescue_section(rebuilt_pd005) == nil, "pd005 rebuild should keep triplet prefix out of rescue-id expansion")
    assert_equal(#rebuilt_pd005.rest_body, #pd005.rest_body, "pd005 rebuild should preserve structured rest-body length")
    assert_equal(
        string.sub(rebuilt_pd005.rest_body, 1, 6),
        string.sub(pd005.rest_body, 1, 6),
        "pd005 rebuild should preserve the structured triplet prefix"
    )
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
    local root = current_dir() .. "/test_list_files_recursive"
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
