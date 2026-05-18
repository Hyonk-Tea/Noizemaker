local format = require("core.format")

local M = {}
M.EVENT_TICK_NUMERATOR = 4
M.EVENT_TICK_DENOMINATOR = 5
M.R11_DEFAULT_TOURIST_HANDLE = 0x007C
M.R11_DEFAULT_ROBOT_CHU_43 = "\067\002\001\000\042\003\000\000\005\000\020\002\018\065"
M.R11_DEFAULT_TOURIST_HEY_43 = "\067\002\003\000\042\003\000\000\005\000\020\002\032\065"
M.R11_DEFAULT_TOURIST_HEY_44 = "\068\002\003\000\042\003\000\000\005\000\020\002\001\065"

M.R11_MIXED_SPECIAL_SUPPORTED = {
    ps007 = true,
    ps008 = true,
    ps008b = true,
    ps009 = true,
    ps009b = true,
    ps011 = true,
    ps012 = true,
    ps013 = true,
}

local function copy_list(list)
    local out = {}
    for i = 1, #list do
        out[i] = list[i]
    end
    return out
end

local function pack_u16(value)
    local lo = value % 256
    local hi = math.floor(value / 256) % 256
    return string.char(lo, hi)
end

local function slice(buf, start_offset, end_offset)
    local len = #buf
    local start_index = math.max(start_offset, 0) + 1
    local end_index = math.min(end_offset, len)
    if end_index < start_index then
        return ""
    end
    return string.sub(buf, start_index, end_index)
end

local function is_integer(value)
    return type(value) == "number" and value % 1 == 0
end

local function normalize_analysis_buffer(buf)
    if type(buf) == "string" then
        return buf
    end
    if type(buf) == "table" and type(buf.getString) == "function" then
        local ok, result = pcall(function()
            return buf:getString()
        end)
        if ok and type(result) == "string" then
            return result
        end
    end
    error("analysis helpers expect a binary string or FileData-like object")
end

local function is_declaration_opcode(value)
    return value ~= nil and value >= 0x0300 and value <= 0x03FF
end

local function to_tick_units(value)
    if type(value) ~= "number" then
        return nil
    end
    return (value * M.EVENT_TICK_NUMERATOR) / M.EVENT_TICK_DENOMINATOR
end

local function declaration_opcode_label(opcode)
    if opcode == 0x0322 then
        return "0322"
    end
    if opcode == 0x0323 then
        return "0323"
    end
    if opcode == 0x0324 then
        return "0324"
    end
    return string.format("%04X", opcode or 0)
end

local function classify_declaration(opcode, u16_2, u16_3)
    if opcode == 0x0322 then
        return {
            opcode_name = "0322",
            kind = "id_only_declaration",
            id = u16_2,
            param = u16_3,
            has_param = u16_3 ~= 0,
            param_hint = u16_3 == 0 and "zero" or "unknown",
        }
    end
    if opcode == 0x0324 then
        local param_hint = "zero"
        if u16_3 ~= 0 then
            if u16_3 <= 0x017F then
                param_hint = "position_like"
            else
                param_hint = "nonzero"
            end
        end
        return {
            opcode_name = "0324",
            kind = "id_and_param_declaration",
            id = u16_2,
            param = u16_3,
            has_param = u16_3 ~= 0,
            param_hint = param_hint,
        }
    end
    if opcode == 0x0323 then
        return {
            opcode_name = "0323",
            kind = "special_tail_declaration",
            id = u16_2,
            param = u16_3,
            has_param = u16_3 ~= 0,
            param_hint = u16_3 == 0 and "zero" or "unknown",
        }
    end
    return {
        opcode_name = declaration_opcode_label(opcode),
        kind = "unknown_declaration",
        id = u16_2,
        param = u16_3,
        has_param = u16_3 ~= 0,
        param_hint = u16_3 == 0 and "zero" or "unknown",
    }
end

local function build_prefix_shape(local_ids, declarations)
    local parts = {}
    if #(local_ids or {}) > 0 then
        parts[#parts + 1] = "L" .. tostring(#local_ids)
    end
    for i = 1, #(declarations or {}) do
        parts[#parts + 1] = declaration_opcode_label(declarations[i].opcode)
    end
    if #parts == 0 then
        return "none"
    end
    return table.concat(parts, "+")
end

local function count_special_steps(steps)
    local count = 0
    for i = 1, #(steps or {}) do
        local code = steps[i]
        if type(steps[i]) == "table" then
            code = steps[i].code
        end
        if code == format.INV.CHU or code == format.INV.HEY or code == format.INV.HOLDCHU or code == format.INV.HOLDHEY then
            count = count + 1
        end
    end
    return count
end

local function is_special_code(code)
    return code == format.INV.CHU or code == format.INV.HEY or code == format.INV.HOLDCHU or code == format.INV.HOLDHEY
end

local function extract_step_code(step)
    if type(step) == "table" then
        return step.code
    end
    return step
end

local function collect_special_positions_and_codes(steps)
    local positions = {}
    local codes = {}
    for i = 1, #(steps or {}) do
        local code = extract_step_code(steps[i])
        if is_special_code(code) then
            positions[#positions + 1] = i
            codes[#codes + 1] = code
        end
    end
    return positions, codes
end

local function special_family(code)
    if code == format.INV.CHU or code == format.INV.HOLDCHU then
        return "chu"
    end
    if code == format.INV.HEY or code == format.INV.HOLDHEY then
        return "hey"
    end
    return nil
end

local function pack_event_record(record)
    return pack_u16(0x074F)
        .. pack_u16(record.u16_1)
        .. pack_u16(record.u16_2)
        .. pack_u16(record.u16_3)
        .. pack_u16(record.u16_4)
        .. pack_u16(record.u16_5)
        .. pack_u16(record.u16_6)
end

local function reindex_special_block(raw, zero_based_index)
    return string.char(string.byte(raw, 1), string.byte(raw, 2), zero_based_index)
        .. slice(raw, 3, #raw)
end

local function step_start_ticks(steps)
    local ticks = {}
    local tick = 0
    for i = 1, #(steps or {}) do
        ticks[i] = tick
        local step = steps[i]
        tick = tick + ((type(step) == "table" and step.gap) or 0)
    end
    return ticks
end

local function ticks_to_event_units(ticks)
    return math.floor(((ticks or 0) * M.EVENT_TICK_DENOMINATOR) / M.EVENT_TICK_NUMERATOR + 0.5)
end

local function is_supported_r11_mixed_special_entry(entry, stream)
    if entry == nil or stream == nil or not M.R11_MIXED_SPECIAL_SUPPORTED[entry.name or ""] then
        return false
    end
    return stream.family_style == "separator_grouped_single_word"
        or stream.family_style == "sequential_single_word"
        or stream.family_style == "sequential_single_word+prefix_4f07"
end

local function special_signature(positions, codes)
    local parts = {}
    for i = 1, #(positions or {}) do
        parts[#parts + 1] = string.format("%d:%02X", positions[i], codes[i] or 0)
    end
    return table.concat(parts, "|")
end

local function find_first_event_record_offset(rest_body)
    for pos = 0, math.min(#rest_body - 2, 30) do
        if (pos % 2) == 0 and format.u16(rest_body, pos) == 0x074F then
            return pos
        end
    end
    return nil
end

function M.scan_animation_indices(entry)
    local rest_body = entry.rest_body or ""
    local blocks = {}
    local unique = {}
    local required_step_codes = {}
    local max_ref = 0
    local pos = 0

    while pos + 3 <= #rest_body do
        local opcode = string.byte(rest_body, pos + 1)
        local marker = string.byte(rest_body, pos + 2)
        if (opcode == 0x43 or opcode == 0x44) and marker == 0x02 then
            local idx = string.byte(rest_body, pos + 3)
            blocks[#blocks + 1] = {
                offset = pos,
                opcode = opcode,
                index = idx,
            }
            if idx > max_ref then
                max_ref = idx
            end
            if not unique[idx] then
                unique[idx] = true
                if idx < #(entry.steps or {}) then
                    required_step_codes[idx] = entry.steps[idx + 1]
                end
            end
            pos = pos + 14
        else
            pos = pos + 2
        end
    end

    local indices = {}
    for idx in pairs(unique) do
        indices[#indices + 1] = idx
    end
    table.sort(indices)

    return {
        blocks = blocks,
        indices = indices,
        required_step_codes = required_step_codes,
        min_safe_step_count = max_ref > 0 and max_ref or 1,
    }
end

function M.min_safe_step_count(entry)
    return M.scan_animation_indices(entry).min_safe_step_count
end

function M.event_units_to_ticks(value)
    return to_tick_units(value)
end

function M.prefix_shape(local_ids, declarations)
    return build_prefix_shape(local_ids, declarations)
end

function M.classify_declaration(opcode, u16_2, u16_3)
    return classify_declaration(opcode, u16_2, u16_3)
end

function M.scan_event_prefix(entry)
    local rest_body = entry.rest_body or ""
    local prefix_len = find_first_event_record_offset(rest_body)
    if prefix_len == nil then
        return nil
    end

    local prefix_words = {}
    for pos = 0, prefix_len - 2, 2 do
        prefix_words[#prefix_words + 1] = format.u16(rest_body, pos)
    end

    local local_ids = {}
    local declarations = {}
    local unknown_words = {}
    local pos = 1
    local expected_local_id_count = math.max((entry and entry.sc or 0) - 1, 0)
    local saw_declaration = false

    while pos <= #prefix_words do
        if pos + 2 <= #prefix_words and is_declaration_opcode(prefix_words[pos]) then
            saw_declaration = true
            declarations[#declarations + 1] = {
                offset = (pos - 1) * 2,
                opcode = prefix_words[pos],
                u16_2 = prefix_words[pos + 1],
                u16_3 = prefix_words[pos + 2],
                classification = classify_declaration(prefix_words[pos], prefix_words[pos + 1], prefix_words[pos + 2]),
            }
            pos = pos + 3
        elseif not saw_declaration and #local_ids < expected_local_id_count then
            local_ids[#local_ids + 1] = prefix_words[pos]
            pos = pos + 1
        else
            unknown_words[#unknown_words + 1] = {
                offset = (pos - 1) * 2,
                value = prefix_words[pos],
            }
            pos = pos + 1
        end
    end

    return {
        prefix_len = prefix_len,
        prefix_words = prefix_words,
        local_ids = local_ids,
        declarations = declarations,
        unknown_words = unknown_words,
        has_exact_local_id_prefix = #local_ids == expected_local_id_count and #unknown_words == 0,
        shape = build_prefix_shape(local_ids, declarations),
    }
end

function M.detect_rescue_section(entry)
    local prefix = M.scan_event_prefix(entry)
    if prefix == nil then
        return nil
    end

    -- Conservative rule for safe ID-list expansion:
    -- only treat the prefix as expandable Rescue IDs when the entire prefix
    -- is exactly step_count - 1 local IDs and contains no declaration triplets.
    if not prefix.has_exact_local_id_prefix or #prefix.local_ids == 0 or #prefix.declarations > 0 then
        return nil
    end

    return {
        prefix_len = prefix.prefix_len,
        ids = copy_list(prefix.local_ids),
    }
end

function M.scan_event_records(entry)
    local prefix = M.scan_event_prefix(entry)
    if prefix == nil then
        return nil
    end

    local rest_body = entry.rest_body or ""
    local records = {}
    local pos = prefix.prefix_len

    -- Event records currently appear as 7 packed u16 values:
    --   0x074F, then six additional u16 fields.
    while pos + 13 < #rest_body do
        if format.u16(rest_body, pos) ~= 0x074F then
            break
        end

        records[#records + 1] = {
            offset = pos,
            opcode = 0x074F,
            u16_1 = format.u16(rest_body, pos + 2),
            u16_2 = format.u16(rest_body, pos + 4),
            u16_3 = format.u16(rest_body, pos + 6),
            u16_4 = format.u16(rest_body, pos + 8),
            u16_5 = format.u16(rest_body, pos + 10),
            u16_6 = format.u16(rest_body, pos + 12),
            tick_3 = to_tick_units(format.u16(rest_body, pos + 6)),
            tick_4 = to_tick_units(format.u16(rest_body, pos + 8)),
            tick_5 = to_tick_units(format.u16(rest_body, pos + 10)),
        }
        pos = pos + 14
    end

    local special_step_count = count_special_steps(entry.steps or {})
    local archetype = "unknown"
    if #records == 0 then
        archetype = "id_prefix_only"
    elseif special_step_count > 0 and #records == special_step_count then
        archetype = "per_special_event"
    elseif special_step_count > 0 and #records == special_step_count * 2 then
        archetype = "double_event_per_special"
    elseif #records == 1 then
        archetype = "single_event_gate"
    end

    return {
        prefix_len = prefix.prefix_len,
        prefix = prefix,
        records = records,
        record_count = #records,
        special_step_count = special_step_count,
        tail_offset = pos,
        tail = slice(rest_body, pos, #rest_body),
        archetype = archetype,
    }
end

function M.scan_rescue_event_records(entry)
    local rescue = M.detect_rescue_section(entry)
    if rescue == nil then
        return nil
    end

    local scan = M.scan_event_records(entry)
    if scan == nil then
        return nil
    end

    scan.ids = copy_list(rescue.ids)
    return scan
end

function M.scan_special_anim_tail(entry)
    local rest_body = entry.rest_body or ""
    local blocks = {}
    local prefix_tokens = {}
    local first_block_pos = nil
    local pos = 0

    while pos + 3 <= #rest_body do
        local opcode = string.byte(rest_body, pos + 1)
        local marker = string.byte(rest_body, pos + 2)
        if (opcode == 0x43 or opcode == 0x44) and marker == 0x02 then
            first_block_pos = pos
            break
        end
        pos = pos + 2
    end

    if first_block_pos == nil then
        return nil
    end

    for prefix_pos = 0, first_block_pos - 2, 2 do
        prefix_tokens[#prefix_tokens + 1] = format.u16(rest_body, prefix_pos)
    end

    pos = first_block_pos
    while pos + 13 < #rest_body do
        local opcode = string.byte(rest_body, pos + 1)
        local marker = string.byte(rest_body, pos + 2)
        if (opcode ~= 0x43 and opcode ~= 0x44) or marker ~= 0x02 then
            break
        end

        blocks[#blocks + 1] = {
            offset = pos,
            opcode = opcode,
            index = string.byte(rest_body, pos + 3),
            raw = slice(rest_body, pos, pos + 14),
            template = string.char(opcode, 0x02) .. "\000" .. slice(rest_body, pos + 3, pos + 14),
        }
        pos = pos + 14
    end

    local tail = slice(rest_body, pos, #rest_body)
    local steps = entry:as_step_list()
    local special_positions, special_codes = collect_special_positions_and_codes(steps)

    local shape = "generic"
    local prefix_ok = true
    for i = 1, #prefix_tokens do
        if prefix_tokens[i] ~= 0x00FE and prefix_tokens[i] ~= 0xFFFF then
            prefix_ok = false
            break
        end
    end
    local only_43 = true
    local same_43_template = true
    local first_43_template = nil
    for i = 1, #blocks do
        if blocks[i].opcode ~= 0x43 then
            only_43 = false
        else
            if first_43_template == nil then
                first_43_template = blocks[i].template
            elseif blocks[i].template ~= first_43_template then
                same_43_template = false
            end
        end
    end

    local chu_only = true
    for i = 1, #special_codes do
        if special_codes[i] ~= format.INV.CHU then
            chu_only = false
            break
        end
    end

    if chu_only and prefix_ok and only_43 and same_43_template then
        shape = "chu_only"
    elseif prefix_ok then
        shape = "mixed_special"
    end

    return {
        prefix_len = first_block_pos,
        prefix_tokens = prefix_tokens,
        blocks = blocks,
        tail = tail,
        special_positions = special_positions,
        special_codes = special_codes,
        special_signature = special_signature(special_positions, special_codes),
        shape = shape,
        chu_only_synth_ok = shape == "chu_only" and tail == "\000\001",
        first_43_template = first_43_template,
    }
end

function M.scan_0325_handle_record_runs(buf, options)
    local data = normalize_analysis_buffer(buf)
    options = options or {}
    local min_records = options.min_records or 3
    local runs = {}
    local off = 0

    while off + 14 <= #data do
        local record_start = off
        local records = {}
        while record_start + 14 <= #data and format.u16(data, record_start + 2) == 0x0325 do
            records[#records + 1] = {
                offset = record_start,
                handle_id = format.u16(data, record_start),
                opcode = format.u16(data, record_start + 2),
                u16_3 = format.u16(data, record_start + 4),
                u16_4 = format.u16(data, record_start + 6),
                u16_5 = format.u16(data, record_start + 8),
                u16_6 = format.u16(data, record_start + 10),
                u16_7 = format.u16(data, record_start + 12),
            }
            record_start = record_start + 14
        end

        if #records >= min_records then
            local handles = {}
            for i = 1, #records do
                handles[i] = records[i].handle_id
            end
            runs[#runs + 1] = {
                start_offset = records[1].offset,
                end_offset = record_start,
                records = records,
                handle_ids = handles,
                count = #records,
            }
            off = record_start
        else
            off = off + 2
        end
    end

    return runs
end

function M.scan_handle_flag_lists(buf, options)
    local data = normalize_analysis_buffer(buf)
    options = options or {}
    local min_records = options.min_records or 3
    local max_handle = options.max_handle or 0xFFFF
    local max_flag = options.max_flag or 0xFFFF
    local runs = {}
    local off = 0

    while off + 8 <= #data do
        local records = {}
        local cursor = off
        local saw_terminator = false

        while cursor + 8 <= #data do
            local handle = format.u32(data, cursor)
            local flag = format.u32(data, cursor + 4)
            if handle == 0 and flag == 0 then
                saw_terminator = true
                cursor = cursor + 8
                break
            end
            if handle == 0 or handle > max_handle or flag > max_flag then
                break
            end
            records[#records + 1] = {
                offset = cursor,
                handle_id = handle,
                flag = flag,
            }
            cursor = cursor + 8
        end

        if saw_terminator and #records >= min_records then
            local handles = {}
            for i = 1, #records do
                handles[i] = records[i].handle_id
            end
            runs[#runs + 1] = {
                start_offset = records[1].offset,
                end_offset = cursor,
                records = records,
                handle_ids = handles,
                count = #records,
            }
            off = cursor
        else
            off = off + 4
        end
    end

    return runs
end

function M.scan_special_handle_usage(entry)
    local stream = M.scan_special_event_stream(entry)
    if stream == nil then
        return nil
    end

    local seen = {}
    local handle_ids = {}
    local events = {}

    for i = 1, #(stream.events or {}) do
        local event = stream.events[i]
        local event_handles = {}
        local event_seen = {}
        for j = 1, #(event.token_words or {}) do
            local value = event.token_words[j].value
            if value ~= 0x00FE and not event_seen[value] then
                event_seen[value] = true
                event_handles[#event_handles + 1] = value
                if not seen[value] then
                    seen[value] = true
                    handle_ids[#handle_ids + 1] = value
                end
            end
        end

        events[#events + 1] = {
            order = event.order,
            step_index = event.step_index,
            zero_based_index = event.zero_based_index,
            visible_code = event.visible_code,
            visible_name = event.visible_name,
            encoded_kind = event.encoded_kind,
            block_kind = event.block_kind,
            handle_ids = event_handles,
            token_word_count = #(event.token_words or {}),
        }
    end

    table.sort(handle_ids)
    return {
        stream = stream,
        handle_ids = handle_ids,
        events = events,
    }
end

function M.find_0325_handle_records(buf, handle_ids, options)
    local runs = M.scan_0325_handle_record_runs(buf, options)
    local wanted = {}
    for i = 1, #(handle_ids or {}) do
        wanted[handle_ids[i]] = true
    end

    local matches = {}
    for i = 1, #runs do
        for j = 1, #runs[i].records do
            local record = runs[i].records[j]
            if wanted[record.handle_id] then
                matches[#matches + 1] = {
                    run_index = i,
                    run_start_offset = runs[i].start_offset,
                    record = record,
                }
            end
        end
    end
    return matches
end

function M.find_handle_flag_records(buf, handle_ids, options)
    local runs = M.scan_handle_flag_lists(buf, options)
    local wanted = {}
    for i = 1, #(handle_ids or {}) do
        wanted[handle_ids[i]] = true
    end

    local matches = {}
    for i = 1, #runs do
        for j = 1, #runs[i].records do
            local record = runs[i].records[j]
            if wanted[record.handle_id] then
                matches[#matches + 1] = {
                    run_index = i,
                    run_start_offset = runs[i].start_offset,
                    record = record,
                }
            end
        end
    end
    return matches
end

function M.build_special_handle_map(entry, chart_buf, scene_buf, options)
    local usage = M.scan_special_handle_usage(entry)
    if usage == nil then
        return nil
    end

    local chart_matches = chart_buf and M.find_0325_handle_records(chart_buf, usage.handle_ids, options) or {}
    local scene_matches = scene_buf and M.find_handle_flag_records(scene_buf, usage.handle_ids, options) or {}

    local by_handle = {}
    for i = 1, #usage.handle_ids do
        by_handle[usage.handle_ids[i]] = {
            handle_id = usage.handle_ids[i],
            chart_records = {},
            scene_records = {},
            events = {},
        }
    end

    for i = 1, #(usage.events or {}) do
        local event = usage.events[i]
        for j = 1, #(event.handle_ids or {}) do
            local handle_id = event.handle_ids[j]
            if by_handle[handle_id] then
                by_handle[handle_id].events[#by_handle[handle_id].events + 1] = event
            end
        end
    end

    for i = 1, #chart_matches do
        local match = chart_matches[i]
        if by_handle[match.record.handle_id] then
            by_handle[match.record.handle_id].chart_records[#by_handle[match.record.handle_id].chart_records + 1] = match
        end
    end

    for i = 1, #scene_matches do
        local match = scene_matches[i]
        if by_handle[match.record.handle_id] then
            by_handle[match.record.handle_id].scene_records[#by_handle[match.record.handle_id].scene_records + 1] = match
        end
    end

    local handles = {}
    for i = 1, #usage.handle_ids do
        handles[#handles + 1] = by_handle[usage.handle_ids[i]]
    end

    return {
        usage = usage,
        handles = handles,
        by_handle = by_handle,
        chart_matches = chart_matches,
        scene_matches = scene_matches,
    }
end

function M.annotate_special_event_tokens(entry, chart_buf, scene_buf, options)
    local stream = M.scan_special_event_stream(entry)
    if stream == nil then
        return nil
    end

    local token_values = {}
    local seen = {}
    for i = 1, #(stream.events or {}) do
        for j = 1, #(stream.events[i].token_words or {}) do
            local value = stream.events[i].token_words[j].value
            if value ~= 0x00FE and not seen[value] then
                seen[value] = true
                token_values[#token_values + 1] = value
            end
        end
    end

    local chart_matches = chart_buf and M.find_0325_handle_records(chart_buf, token_values, options) or {}
    local scene_matches = scene_buf and M.find_handle_flag_records(scene_buf, token_values, options) or {}

    local by_value = {}
    for i = 1, #token_values do
        local value = token_values[i]
        by_value[value] = {
            value = value,
            chart_records = {},
            scene_records = {},
        }
    end

    for i = 1, #chart_matches do
        local match = chart_matches[i]
        if by_value[match.record.handle_id] then
            by_value[match.record.handle_id].chart_records[#by_value[match.record.handle_id].chart_records + 1] = match
        end
    end

    for i = 1, #scene_matches do
        local match = scene_matches[i]
        if by_value[match.record.handle_id] then
            by_value[match.record.handle_id].scene_records[#by_value[match.record.handle_id].scene_records + 1] = match
        end
    end

    local values = {}
    for i = 1, #token_values do
        local item = by_value[token_values[i]]
        if #item.chart_records > 0 and #item.scene_records > 0 then
            item.classification = "catalog_and_scene_handle"
        elseif #item.chart_records > 0 then
            item.classification = "catalog_only_handle"
        elseif #item.scene_records > 0 then
            item.classification = "scene_only_handle"
        else
            item.classification = "unresolved_token"
        end
        values[#values + 1] = item
    end

    return {
        stream = stream,
        values = values,
        by_value = by_value,
    }
end

function M.scan_special_event_stream(entry)
    local scan = M.scan_special_anim_tail(entry)
    if scan == nil then
        return nil
    end

    local prefix_elements = {}
    local token_elements = {}
    local declarations = {}
    local prefix_event_records = {}
    local separators = {}
    local trailing_unknown_words = {}
    local words = scan.prefix_tokens or {}
    local pos = 1
    while pos <= #words do
        local word = words[pos]
        if word == 0xFFFF then
            local sep = {
                kind = "separator",
                value = word,
                offset_words = pos - 1,
            }
            prefix_elements[#prefix_elements + 1] = sep
            separators[#separators + 1] = sep
            pos = pos + 1
        elseif pos + 6 <= #words and word == 0x074F then
            local record = {
                kind = "event_record",
                opcode = 0x074F,
                u16_1 = words[pos + 1],
                u16_2 = words[pos + 2],
                u16_3 = words[pos + 3],
                u16_4 = words[pos + 4],
                u16_5 = words[pos + 5],
                u16_6 = words[pos + 6],
                tick_3 = to_tick_units(words[pos + 3]),
                tick_4 = to_tick_units(words[pos + 4]),
                tick_5 = to_tick_units(words[pos + 5]),
                offset_words = pos - 1,
            }
            prefix_elements[#prefix_elements + 1] = record
            prefix_event_records[#prefix_event_records + 1] = record
            pos = pos + 7
        elseif pos + 2 <= #words and is_declaration_opcode(word) then
            local decl = {
                kind = "declaration",
                opcode = word,
                u16_2 = words[pos + 1],
                u16_3 = words[pos + 2],
                offset_words = pos - 1,
                classification = classify_declaration(word, words[pos + 1], words[pos + 2]),
            }
            prefix_elements[#prefix_elements + 1] = decl
            declarations[#declarations + 1] = decl
            pos = pos + 3
        else
            local token = {
                kind = "token",
                value = word,
                offset_words = pos - 1,
                token_kind = word == 0x00FE and "chu_token" or "variant_token",
            }
            prefix_elements[#prefix_elements + 1] = token
            token_elements[#token_elements + 1] = token
            pos = pos + 1
        end
    end

    local token_groups = {}
    local current_group = nil
    for i = 1, #prefix_elements do
        local element = prefix_elements[i]
        if element.kind == "token" then
            if current_group == nil then
                current_group = {
                    order = #token_groups + 1,
                    words = {},
                }
            end
            current_group.words[#current_group.words + 1] = element
        elseif element.kind == "separator" then
            if current_group ~= nil then
                current_group.ended_by_separator = true
                token_groups[#token_groups + 1] = current_group
                current_group = nil
            end
        end
    end
    if current_group ~= nil then
        current_group.ended_by_separator = false
        token_groups[#token_groups + 1] = current_group
    end

    local events = {}
    local blocks = scan.blocks or {}
    local block_cursor = 1
    local token_cursor = 1
    local group_cursor = 1
    local special_positions = scan.special_positions or {}
    local special_codes = scan.special_codes or {}

    local function fallback_token_words_for_event(event_index)
        local event_token_words = {}
        if event_index == #special_positions then
            while token_cursor <= #token_elements do
                event_token_words[#event_token_words + 1] = token_elements[token_cursor]
                token_cursor = token_cursor + 1
            end
        elseif token_cursor <= #token_elements then
            event_token_words[#event_token_words + 1] = token_elements[token_cursor]
            token_cursor = token_cursor + 1
        end
        return event_token_words
    end

    local function grouped_token_words_for_event()
        if group_cursor > #token_groups then
            return {}
        end
        local group = token_groups[group_cursor]
        group_cursor = group_cursor + 1
        return group.words
    end

    for i = 1, #special_positions do
        local step_index = special_positions[i]
        local code = special_codes[i]
        local expected_index = step_index - 1
        local event_blocks = {}
        while block_cursor <= #blocks and blocks[block_cursor].index == expected_index do
            event_blocks[#event_blocks + 1] = blocks[block_cursor]
            block_cursor = block_cursor + 1
        end

        local event_token_words
        if #token_groups == #special_positions then
            event_token_words = grouped_token_words_for_event()
        else
            event_token_words = fallback_token_words_for_event(i)
        end

        local block_kind = "none"
        if #event_blocks == 1 and event_blocks[1].opcode == 0x43 then
            block_kind = "single_43"
        elseif #event_blocks == 2 and event_blocks[1].opcode == 0x43 and event_blocks[2].opcode == 0x44 then
            block_kind = "43_44_pair"
        elseif #event_blocks > 0 then
            block_kind = "other"
        end

        local encoded_kind = "unknown"
        if code == format.INV.CHU or code == format.INV.HOLDCHU then
            if #event_token_words >= 1 and event_token_words[1].value == 0x00FE and block_kind == "single_43" then
                encoded_kind = "chu_event"
            end
        elseif code == format.INV.HEY or code == format.INV.HOLDHEY then
            if block_kind == "43_44_pair" then
                encoded_kind = "hey_event"
            end
        end

        events[#events + 1] = {
            order = i,
            step_index = step_index,
            zero_based_index = expected_index,
            visible_code = code,
            visible_name = format.step_display_name(code),
            token_words = event_token_words,
            blocks = event_blocks,
            block_kind = block_kind,
            encoded_kind = encoded_kind,
        }
    end

    while group_cursor <= #token_groups do
        local group = token_groups[group_cursor]
        for i = 1, #group.words do
            trailing_unknown_words[#trailing_unknown_words + 1] = group.words[i]
        end
        group_cursor = group_cursor + 1
    end

    while token_cursor <= #token_elements do
        trailing_unknown_words[#trailing_unknown_words + 1] = token_elements[token_cursor]
        token_cursor = token_cursor + 1
    end

    local unassigned_blocks = {}
    while block_cursor <= #blocks do
        unassigned_blocks[#unassigned_blocks + 1] = blocks[block_cursor]
        block_cursor = block_cursor + 1
    end

    local assignment_style = "unknown"
    if #events == 0 then
        assignment_style = "no_events"
    elseif #token_groups == #events then
        local all_single_word = true
        local any_multi_word = false
        for i = 1, #events do
            local word_count = #(events[i].token_words or {})
            if word_count ~= 1 then
                all_single_word = false
            end
            if word_count > 1 then
                any_multi_word = true
            end
        end
        if all_single_word then
            assignment_style = "separator_grouped_single_word"
        elseif any_multi_word then
            assignment_style = "separator_grouped_multi_word"
        else
            assignment_style = "separator_grouped"
        end
    else
        local total_token_words = 0
        local any_multi_word = false
        for i = 1, #events do
            local word_count = #(events[i].token_words or {})
            total_token_words = total_token_words + word_count
            if word_count > 1 then
                any_multi_word = true
            end
        end
        if total_token_words == #events then
            assignment_style = "sequential_single_word"
        elseif any_multi_word then
            assignment_style = "sequential_mixed_width"
        else
            assignment_style = "sequential"
        end
    end

    local family_style = assignment_style
    if #prefix_event_records > 0 then
        family_style = family_style .. "+prefix_4f07"
    end
    if #declarations > 0 then
        family_style = family_style .. "+decl"
    end

    return {
        tail_scan = scan,
        prefix_elements = prefix_elements,
        prefix_declarations = declarations,
        prefix_event_records = prefix_event_records,
        separators = separators,
        token_elements = token_elements,
        token_groups = token_groups,
        events = events,
        trailing_unknown_words = trailing_unknown_words,
        unassigned_blocks = unassigned_blocks,
        assignment_style = assignment_style,
        family_style = family_style,
    }
end

function M.synthesize_chu_only_special_anim_tail(entry, new_steps)
    local scan = M.scan_special_anim_tail(entry)
    if scan == nil or not scan.chu_only_synth_ok then
        return nil, "entry is not in the supported chu-only special-anim family"
    end

    local steps = new_steps or entry:as_step_list()
    local positions, codes = collect_special_positions_and_codes(steps)
    for i = 1, #codes do
        if codes[i] ~= format.INV.CHU then
            return nil, "only CHU special synthesis is currently supported"
        end
    end

    local prefix_parts = {}
    for i = 1, #positions do
        if i > 1 and positions[i] > (positions[i - 1] + 1) then
            prefix_parts[#prefix_parts + 1] = pack_u16(0xFFFF)
        end
        prefix_parts[#prefix_parts + 1] = pack_u16(0x00FE)
    end

    local block_parts = {}
    for i = 1, #positions do
        local index = positions[i] - 1
        block_parts[#block_parts + 1] = string.char(0x43, 0x02, index) .. slice(scan.first_43_template, 3, #scan.first_43_template)
    end

    return table.concat(prefix_parts) .. table.concat(block_parts) .. "\000\001"
end

function M.synthesize_r11_mixed_special_anim_tail(entry, new_steps)
    local stream = M.scan_special_event_stream(entry)
    if not is_supported_r11_mixed_special_entry(entry, stream) then
        return nil, "entry is not in the supported r11 mixed-special family"
    end

    local steps = new_steps or entry:as_step_list()
    local positions, codes = collect_special_positions_and_codes(steps)
    local start_ticks = step_start_ticks(steps)
    local original_events = stream.events or {}
    local original_prefix_records = stream.prefix_event_records or {}
    local tail_scan = stream.tail_scan or {}
    local tail = tail_scan.tail or "\000\001"
    local synthesized_events = {}
    local prefix_words = {}
    local block_parts = {}

    local function default_hey_blocks()
        return {
            M.R11_DEFAULT_TOURIST_HEY_43,
            M.R11_DEFAULT_TOURIST_HEY_44,
        }
    end

    local function default_chu_blocks()
        return {
            M.R11_DEFAULT_ROBOT_CHU_43,
        }
    end

    for i = 1, #positions do
        local code = codes[i]
        local family = special_family(code)
        if family == nil then
            return nil, "only CHU and HEY special synthesis is currently supported for r11"
        end

        local original = original_events[i]
        local original_family = original and special_family(original.visible_code) or nil
        local token_word
        local block_templates
        local prefix_template

        if original ~= nil and original_family == family then
            token_word = original.token_words[1] and original.token_words[1].value or nil
            block_templates = {}
            for j = 1, #(original.blocks or {}) do
                block_templates[j] = original.blocks[j].raw
            end
            if family == "hey" and original_prefix_records[i] ~= nil then
                prefix_template = original_prefix_records[i]
            end
        end

        if family == "chu" then
            token_word = token_word or 0x00FE
            block_templates = block_templates or default_chu_blocks()
        else
            token_word = token_word or M.R11_DEFAULT_TOURIST_HANDLE
            block_templates = block_templates or default_hey_blocks()
            if prefix_template == nil and #original_prefix_records > 0 then
                prefix_template = original_prefix_records[math.min(i, #original_prefix_records)]
            end
        end

        synthesized_events[#synthesized_events + 1] = {
            order = i,
            position = positions[i],
            code = code,
            family = family,
            token_word = token_word,
            block_templates = block_templates,
            prefix_template = prefix_template,
            tick = start_ticks[positions[i]] or 0,
        }
    end

    if stream.family_style == "sequential_single_word+prefix_4f07" then
        for i = 1, #synthesized_events do
            prefix_words[#prefix_words + 1] = pack_u16(synthesized_events[i].token_word)
        end
        for i = 1, #synthesized_events do
            local event = synthesized_events[i]
            if event.family ~= "hey" then
                return nil, "r11 prefix_4f07 special families currently only support HEY events"
            end
            local prefix_template = event.prefix_template or original_prefix_records[1]
            if prefix_template == nil then
                return nil, "missing prefix event-record template for r11 HEY family"
            end
            prefix_words[#prefix_words + 1] = pack_event_record({
                u16_1 = prefix_template.u16_1,
                u16_2 = prefix_template.u16_2,
                u16_3 = ticks_to_event_units(event.tick),
                u16_4 = prefix_template.u16_4,
                u16_5 = prefix_template.u16_5,
                u16_6 = prefix_template.u16_6,
            })
        end
    elseif stream.family_style == "sequential_single_word" then
        for i = 1, #synthesized_events do
            prefix_words[#prefix_words + 1] = pack_u16(synthesized_events[i].token_word)
        end
    elseif stream.family_style == "separator_grouped_single_word" then
        for i = 1, #synthesized_events do
            if i > 1 and synthesized_events[i].position > (synthesized_events[i - 1].position + 1) then
                prefix_words[#prefix_words + 1] = pack_u16(0xFFFF)
            end
            prefix_words[#prefix_words + 1] = pack_u16(synthesized_events[i].token_word)
        end
    else
        return nil, "unsupported r11 mixed-special family style: " .. tostring(stream.family_style)
    end

    for i = 1, #synthesized_events do
        local event = synthesized_events[i]
        local zero_based_index = event.position - 1
        if event.family == "chu" then
            block_parts[#block_parts + 1] = reindex_special_block(event.block_templates[1], zero_based_index)
        else
            if #(event.block_templates or {}) < 2 then
                return nil, "missing HEY block templates for r11 mixed-special synthesis"
            end
            block_parts[#block_parts + 1] = reindex_special_block(event.block_templates[1], zero_based_index)
            block_parts[#block_parts + 1] = reindex_special_block(event.block_templates[2], zero_based_index)
        end
    end

    return table.concat(prefix_words) .. table.concat(block_parts) .. tail
end

function M.synthesize_supported_special_anim_tail(entry, new_steps)
    local synthesized_tail, synth_err = M.synthesize_chu_only_special_anim_tail(entry, new_steps)
    if synthesized_tail ~= nil then
        return synthesized_tail, nil
    end
    if synth_err == "entry is not in the supported chu-only special-anim family" then
        return M.synthesize_r11_mixed_special_anim_tail(entry, new_steps)
    end
    return nil, synth_err
end

function M.special_anim_tail_change_info(entry, new_steps)
    local scan = M.scan_special_anim_tail(entry)
    if scan == nil then
        return nil
    end

    local positions, codes = collect_special_positions_and_codes(new_steps or entry:as_step_list())
    local signature = special_signature(positions, codes)
    return {
        scan = scan,
        new_special_positions = positions,
        new_special_codes = codes,
        new_special_signature = signature,
        changed = signature ~= scan.special_signature,
    }
end

function M.expand_rescue_ids(entry, rest_body, new_step_count)
    local rescue = M.detect_rescue_section(entry)
    if rescue == nil then
        return rest_body
    end

    local target_count = math.max(new_step_count - 1, 0)
    if target_count == #rescue.ids then
        return rest_body
    end

    local prefix_parts = {}
    if target_count > 0 then
        for i = 0, target_count - 1 do
            prefix_parts[#prefix_parts + 1] = pack_u16(rescue.ids[(i % #rescue.ids) + 1])
        end
    end

    return table.concat(prefix_parts) .. slice(rest_body, rescue.prefix_len, #rest_body)
end

function M.validate_mod(entry, new_steps, options)
    options = options or {}
    new_steps = new_steps or {}

    local warnings = {}
    local errors = {}
    local new_step_count = #new_steps
    local structure_ok = true
    local effective_timing = entry and entry.timing or 0
    local tail_change = nil
    local supported_special_tail = nil

    local function warn(message)
        warnings[#warnings + 1] = message
    end

    local function fail(message)
        errors[#errors + 1] = message
    end

    if entry == nil then
        fail("Entry is required.")
        return { ok = false, warnings = warnings, errors = errors }
    end

    tail_change = M.special_anim_tail_change_info(entry, new_steps)
    if tail_change ~= nil and tail_change.changed then
        local synthesized_tail = nil
        local synth_err = nil
        synthesized_tail, synth_err = M.synthesize_supported_special_anim_tail(entry, new_steps)
        supported_special_tail = synthesized_tail ~= nil and {
            synthesized_tail = synthesized_tail,
            synth_err = synth_err,
        } or {
            synthesized_tail = nil,
            synth_err = synth_err,
        }
    end

    if options.timing ~= nil and is_integer(options.timing) and options.timing >= 0 then
        effective_timing = options.timing
    end

    for i, step in ipairs(new_steps) do
        if type(step) ~= "table" then
            fail(string.format("Step %d is missing or invalid.", i))
            structure_ok = false
        else
            if not is_integer(step.code) or step.code < 0 or step.code > 255 then
                fail(string.format("Step %d code must be an integer byte (0..255).", i))
                structure_ok = false
            end
            if i < new_step_count then
                if not is_integer(step.gap) or step.gap < 0 or step.gap > 0xFFFF then
                    fail(string.format("Gap after step %d must be an integer u16 value (0..65535).", i))
                    structure_ok = false
                end
            end
        end
    end

    local min_safe = M.min_safe_step_count(entry)
    if new_step_count < min_safe then
        fail(string.format(
            "%s has animation data that references step index %d. Minimum safe step count is %d; attempted %d.",
            entry.name,
            min_safe,
            min_safe,
            new_step_count
        ))
    end

    local scan = M.scan_animation_indices(entry)
    local effective_anim_indices = options.anim_indices or scan.indices
    if options.anim_indices ~= nil and #options.anim_indices ~= #scan.indices then
        fail(string.format("new_anim_indices must have %d elements.", #scan.indices))
    end

    if #effective_anim_indices > 0 then
        for slot, target_index in ipairs(effective_anim_indices) do
            if not is_integer(target_index) then
                fail(string.format("Animation index %d must be an integer.", slot))
            elseif target_index < 0 or target_index >= new_step_count then
                fail(string.format(
                    "Animation index %d points to step %d, but valid step indices are 0..%d.",
                    slot,
                    target_index,
                    math.max(new_step_count - 1, 0)
                ))
            else
                local required_code = scan.required_step_codes[scan.indices[slot]]
                local target_step = new_steps[target_index + 1]
                if required_code ~= nil
                    and target_step ~= nil
                    and target_step.code ~= required_code
                    and not (supported_special_tail and supported_special_tail.synthesized_tail ~= nil)
                then
                    fail(string.format(
                        "Animation slot %d requires %s at step %d, but found %s.",
                        slot,
                        format.step_display_name(required_code),
                        target_index,
                        format.step_display_name(target_step.code)
                    ))
                end
            end
        end
    end

    if structure_ok then
        local gaps = {}
        for i = 1, math.max(new_step_count - 1, 0) do
            gaps[i] = new_steps[i].gap
        end

        local implied_last_gap = format.implied_last_gap(effective_timing, gaps)
        if implied_last_gap < 0 then
            fail(string.format(
                "Stored gaps exceed the loop length by %dt; implied final gap would be negative.",
                -implied_last_gap
            ))
        elseif implied_last_gap == 0 and new_step_count > 0 then
            warn("A step lands on the final tick of the sequence; this is a known crash risk.")
        end

        for i = 1, math.max(new_step_count - 1, 0) do
            if new_steps[i].gap == 0 then
                warn(string.format(
                    "Gap after step %d is 0 ticks; Autoplay can fail on zero-gap followups.",
                    i - 1
                ))
            end
        end
    end

    local rescue = M.detect_rescue_section(entry)
    if rescue ~= nil then
        local target_id_count = math.max(new_step_count - 1, 0)
        if target_id_count ~= #rescue.ids then
            warn(string.format(
                "Rescue Section detected; local rescue IDs will be resized from %d to %d entries.",
                #rescue.ids,
                target_id_count
            ))
        end

        local original_special = 0
        local new_special = 0
        for i = 1, #(entry.steps or {}) do
            if entry.steps[i] == 1 or entry.steps[i] == 2 then
                original_special = original_special + 1
            end
        end
        for i = 1, new_step_count do
            if new_steps[i].code == 1 or new_steps[i].code == 2 then
                new_special = new_special + 1
            end
        end
        if new_special > original_special then
            warn("Extra HEY or CHU inputs in a Rescue Section can spawn unintended entities.")
        end
    end

    if tail_change ~= nil and tail_change.changed then
        local synthesized_tail = supported_special_tail and supported_special_tail.synthesized_tail or nil
        local synth_err = supported_special_tail and supported_special_tail.synth_err or nil
        if synthesized_tail == nil then
            fail(string.format(
                "%s has hidden special-event data tied to CHU/HEY prompts. Changing those prompts is not supported for this entry yet.",
                entry.name
            ))
            if synth_err ~= nil then
                fail("Special-tail synthesis detail: " .. tostring(synth_err))
            end
        end
    end

    if options.start_delay ~= nil then
        if not is_integer(options.start_delay) then
            fail("start_delay must be an integer tick count.")
        elseif options.start_delay < 0 or options.start_delay > 0xFFFF then
            warn("start_delay will be clamped to the u16 range 0..65535 during rebuild.")
        end
    end

    if options.timing ~= nil then
        if not is_integer(options.timing) then
            fail("timing must be an integer quarter-note count.")
        elseif options.timing < 0 or options.timing > 0xFFFF then
            warn("timing will be clamped to the u16 range 0..65535 during rebuild.")
        end
    end

    return {
        ok = #errors == 0,
        warnings = warnings,
        errors = errors,
    }
end

return M
