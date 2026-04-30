local format = require("core.format")

local M = {}

M.COMMON_GAP_LO_BYTES = {
    [0x06] = true,
    [0x0C] = true,
    [0x12] = true,
    [0x18] = true,
    [0x30] = true,
    [0x48] = true,
    [0x60] = true,
}

local function normalize_buffer(buf)
    if type(buf) == "string" then
        return buf
    end

    local ok, result = pcall(function()
        return buf:getString()
    end)
    if ok and type(result) == "string" then
        return result
    end

    error("expected a binary string or FileData-like object")
end

local function trunc_to_int(value)
    local n = tonumber(value)
    if n == nil then
        error("value must be numeric")
    end
    if n >= 0 then
        return math.floor(n)
    end
    return math.ceil(n)
end

local function pack_u16(value)
    local lo = value % 256
    local hi = math.floor(value / 256) % 256
    return string.char(lo, hi)
end

local function pack_u32(value)
    local b0 = value % 256
    local b1 = math.floor(value / 256) % 256
    local b2 = math.floor(value / 65536) % 256
    local b3 = math.floor(value / 16777216) % 256
    return string.char(b0, b1, b2, b3)
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

local function write_u16(buf, offset, value)
    return slice(buf, 0, offset) .. pack_u16(value) .. slice(buf, offset + 2, #buf)
end

local function write_u32(buf, offset, value)
    return slice(buf, 0, offset) .. pack_u32(value) .. slice(buf, offset + 4, #buf)
end

local function read_c_string_ascii_ignore(buf, offset)
    if offset >= #buf then
        return ""
    end

    local chars = {}
    local pos = offset
    while pos < #buf do
        local byte = string.byte(buf, pos + 1)
        if byte == 0 then
            break
        end
        if byte < 128 then
            chars[#chars + 1] = string.char(byte)
        end
        pos = pos + 1
    end
    return table.concat(chars)
end

local function bytes_to_string(bytes)
    if #bytes == 0 then
        return ""
    end

    local parts = {}
    local chunk_size = 8000
    for i = 1, #bytes, chunk_size do
        local last = math.min(i + chunk_size - 1, #bytes)
        parts[#parts + 1] = string.char(unpack(bytes, i, last))
    end
    return table.concat(parts)
end

local function collect_codes_and_hits(new_steps)
    local codes = {}
    local hits = {}
    for i, step in ipairs(new_steps) do
        codes[i] = step.code
        if i < #new_steps then
            hits[i] = step.gap
        end
    end
    return codes, hits
end

local function resolve_mod(mod)
    if mod == nil then
        return nil, nil, nil, nil
    end

    if mod.steps ~= nil or mod.new_steps ~= nil or mod.anim_indices ~= nil or mod.start_delay ~= nil or mod.timing ~= nil then
        return mod.steps or mod.new_steps, mod.anim_indices, mod.start_delay, mod.timing
    end

    if mod[1] ~= nil and type(mod[1]) == "table" and mod[1].code ~= nil then
        return mod, nil, nil, nil
    end

    if mod[1] ~= nil then
        if mod[4] ~= nil then
            return mod[1], mod[2], mod[3], mod[4]
        end
        if mod[3] ~= nil then
            return mod[1], mod[2], mod[3], nil
        end
        return mod[1], mod[2], nil, nil
    end

    return mod, nil, nil, nil
end

function M.encode_start_delay(step_count, delay_ticks)
    delay_ticks = trunc_to_int(delay_ticks)
    if delay_ticks < 0 then
        delay_ticks = 0
    elseif delay_ticks > 0xFFFF then
        delay_ticks = 0xFFFF
    end

    if step_count % 2 ~= 0 then
        return string.char(0) .. pack_u16(delay_ticks)
    end
    return pack_u16(delay_ticks)
end

function M.find_shifted_start_delay_entries(buf)
    local b = normalize_buffer(buf)
    if slice(b, 0, 4) ~= "DGSH" then
        return {}
    end

    local pt = format.u32(b, 0x18 + 6 * 4)
    local cnt = format.u16(b, 0x08 + 6 * 2)
    local found = {}

    for i = 0, cnt - 1 do
        local dp = format.u32(b, pt + i * 8)
        local np = format.u32(b, pt + i * 8 + 4)
        if dp < #b and dp + 24 <= #b then
            local sc = format.u16(b, dp + 16)
            if sc ~= 0 and sc <= 1024 and sc % 2 ~= 0 then
                local term_off = dp + 20 + sc
                if term_off + 4 <= #b then
                    local looks_shifted =
                        string.byte(b, term_off + 1) ~= 0 and
                        string.byte(b, term_off + 2) == 0 and
                        M.COMMON_GAP_LO_BYTES[string.byte(b, term_off + 3)] and
                        string.byte(b, term_off + 4) == 0

                    if looks_shifted then
                        local name = read_c_string_ascii_ignore(b, np)
                        found[#found + 1] = { name, term_off }
                    end
                end
            end
        end
    end

    return found
end

function M.normalize_shifted_start_delay_layout(buf)
    local repairs = M.find_shifted_start_delay_entries(buf)
    if #repairs == 0 then
        return normalize_buffer(buf), {}
    end

    local data = normalize_buffer(buf)
    local shift = 0
    local repaired_names = {}

    for _, repair in ipairs(repairs) do
        local name = repair[1]
        local original_pos = repair[2]
        local pos = original_pos + shift

        data = slice(data, 0, pos) .. string.char(0) .. slice(data, pos, #data)
        repaired_names[#repaired_names + 1] = name

        local pt = format.u32(data, 0x18 + 6 * 4)
        local cnt = format.u16(data, 0x08 + 6 * 2)
        for i = 0, cnt - 1 do
            local off = pt + i * 8
            for j = 0, 1 do
                local p = off + j * 4
                local v = format.u32(data, p)
                if v >= pos then
                    data = write_u32(data, p, v + 1)
                end
            end
        end

        for i = 0, 7 do
            local offset = 0x18 + i * 4
            local value = format.u32(data, offset)
            if value ~= 0 and value >= pos then
                data = write_u32(data, offset, value + 1)
            end
        end

        shift = shift + 1
    end

    data = write_u32(data, 0x04, #data)
    return data, repaired_names
end

function M.expand_local_id_list_if_needed(entry, rest_body, new_step_count)
    local prefix_len, ids = format.local_id_list_info(entry)
    if prefix_len == nil then
        return rest_body
    end

    local target_count = math.max(new_step_count - 1, 0)
    if target_count == #ids then
        return rest_body
    end

    local parts = {}
    if target_count > 0 then
        for i = 0, target_count - 1 do
            parts[#parts + 1] = pack_u16(ids[(i % #ids) + 1])
        end
    end

    return table.concat(parts) .. slice(rest_body, prefix_len, #rest_body)
end

function M.rebuild_entry(entry, new_steps, options)
    options = options or {}
    if new_steps == nil then
        new_steps = entry:as_step_list()
    end

    local codes, new_hits = collect_codes_and_hits(new_steps)
    local step_count = #codes
    local total = options.timing
    if total == nil then
        total = entry.timing
    end
    local start_delay = options.start_delay
    if start_delay == nil then
        start_delay = entry.start_delay
    end
    local new_term = M.encode_start_delay(step_count, start_delay)

    local buf = entry.raw
    if format.local_id_list_info(entry) == nil then
        buf = write_u16(buf, 8, step_count)
    end

    local parts = {
        buf,
        entry.flag,
        string.char(0x31, math.floor((5 * step_count + 7) / 2) % 256),
        pack_u16(step_count),
        pack_u16(total),
    }

    for i = 1, #codes do
        parts[#parts + 1] = string.char(codes[i])
    end
    parts[#parts + 1] = new_term

    for i = 1, #new_hits do
        parts[#parts + 1] = pack_u16(new_hits[i])
    end

    local new_ff_prefix
    if entry.ff_prefix_count == entry.sc * 2 then
        local ff_parts = {}
        for i = 1, step_count do
            ff_parts[i] = "\255\255"
        end
        new_ff_prefix = table.concat(ff_parts)
    else
        new_ff_prefix = string.rep("\255", entry.ff_prefix_count)
    end

    local rest_body = entry.rest_body
    local new_anim_indices = options.anim_indices
    if new_anim_indices ~= nil then
        local orig_indices = entry:get_anim_indices()
        if #new_anim_indices ~= #orig_indices then
            error(string.format("new_anim_indices must have %d elements", #orig_indices))
        end

        local index_map = {}
        for i = 1, #orig_indices do
            index_map[orig_indices[i]] = new_anim_indices[i]
        end

        local bytes = { string.byte(rest_body, 1, #rest_body) }
        local pos = 1
        while pos + 2 <= #bytes do
            if (bytes[pos] == 0x43 or bytes[pos] == 0x44) and bytes[pos + 1] == 0x02 then
                local old_idx = bytes[pos + 2]
                if index_map[old_idx] ~= nil then
                    bytes[pos + 2] = index_map[old_idx]
                end
                pos = pos + 14
            else
                pos = pos + 2
            end
        end
        rest_body = bytes_to_string(bytes)
    end

    rest_body = M.expand_local_id_list_if_needed(entry, rest_body, step_count)
    parts[#parts + 1] = new_ff_prefix
    parts[#parts + 1] = rest_body
    return table.concat(parts)
end

function M.apply_mods(buffer, entries, mods)
    local data = normalize_buffer(buffer)
    local shift = 0

    for _, entry in ipairs(entries) do
        local mod = mods[entry.name]
        if mod ~= nil then
            local new_steps, new_anim_indices, start_delay, timing = resolve_mod(mod)
            local new_block = M.rebuild_entry(entry, new_steps, {
                anim_indices = new_anim_indices,
                start_delay = start_delay,
                timing = timing,
            })

            local old_start = entry.dp + shift
            local old_end = entry.np + shift
            local old_size = old_end - old_start
            local new_size = #new_block
            local delta = new_size - old_size

            data = slice(data, 0, old_start) .. new_block .. slice(data, old_end, #data)
            shift = shift + delta

            local pt = format.u32(data, 0x18 + 6 * 4)
            local cnt = format.u16(data, 0x08 + 6 * 2)
            for i = 0, cnt - 1 do
                local off = pt + i * 8
                for j = 0, 1 do
                    local p = off + j * 4
                    local v = format.u32(data, p)
                    if v >= old_end then
                        data = write_u32(data, p, v + delta)
                    end
                end
            end

            for i = 0, 7 do
                local offset = 0x18 + i * 4
                local value = format.u32(data, offset)
                if value ~= 0 and value >= old_end then
                    data = write_u32(data, offset, value + delta)
                end
            end

            data = write_u32(data, entry.ptr_off + 4, entry.dp + shift + (new_size - delta))
        end
    end

    data = write_u32(data, 0x04, #data)
    return data
end

M.rebuild = M.rebuild_entry
M.apply = M.apply_mods

return M
