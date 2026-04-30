local M = {}

M.GAME_TO_INTERNAL = {
    UP = 3,
    RIGHT = 4,
    DOWN = 5,
    LEFT = 6,
}

M.INTERNAL_TO_GAME = {
    [3] = "UP",
    [4] = "RIGHT",
    [5] = "DOWN",
    [6] = "LEFT",
}

M.MOVES = {
    [0] = "REST",
    [1] = "CHU",
    [2] = "HEY",
    [3] = "LEFT",
    [4] = "UP",
    [5] = "RIGHT",
    [6] = "DOWN",
    [9] = "HOLDCHU",
    [10] = "HOLDHEY",
    [11] = "HOLDUP",
    [12] = "HOLDRIGHT",
    [13] = "HOLDDOWN",
    [14] = "HOLDLEFT",
}

M.INV = {}
for code, name in pairs(M.MOVES) do
    M.INV[name] = code
end

M.TICK_CYCLE = { 6, 12, 18, 24, 48, 72 }

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

    error("parse expects a binary string or FileData-like object")
end

local function idiv(a, b)
    if b == 0 then
        error("division by zero")
    end
    return math.floor(a / b)
end

local function byte_at(buf, offset)
    return string.byte(buf, offset + 1)
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

local function bytes_to_list(buf)
    local out = {}
    for i = 1, #buf do
        out[i] = string.byte(buf, i)
    end
    return out
end

local function read_c_string_ascii_ignore(buf, offset)
    if offset >= #buf then
        return ""
    end

    local chars = {}
    local e = offset
    while e < #buf do
        local b = byte_at(buf, e)
        if b == 0 then
            break
        end
        if b < 128 then
            chars[#chars + 1] = string.char(b)
        end
        e = e + 1
    end
    return table.concat(chars)
end

function M.u16(buf, offset)
    buf = normalize_buffer(buf)
    local b0 = byte_at(buf, offset)
    local b1 = byte_at(buf, offset + 1)
    return b0 + b1 * 256
end

function M.u32(buf, offset)
    buf = normalize_buffer(buf)
    local b0 = byte_at(buf, offset)
    local b1 = byte_at(buf, offset + 1)
    local b2 = byte_at(buf, offset + 2)
    local b3 = byte_at(buf, offset + 3)
    return b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
end

function M.term_len(step_count)
    if step_count % 2 ~= 0 then
        return 3
    end
    return 2
end

function M.decode_start_delay(step_count, term_bytes)
    if step_count % 2 ~= 0 then
        if #term_bytes >= 3 then
            return M.u16(term_bytes, 1)
        end
        return 0
    end
    if #term_bytes >= 2 then
        return M.u16(term_bytes, 0)
    end
    return 0
end

function M.base_name(name)
    return (name:gsub("[a-z]$", ""))
end

function M.is_raw_byte(code)
    return M.MOVES[code] == nil and M.INTERNAL_TO_GAME[code] == nil
end

function M.step_display_name(code)
    local name = M.INTERNAL_TO_GAME[code] or M.MOVES[code]
    if name ~= nil then
        return name
    end
    return string.format("0x%02X", code)
end

function M.total_ticks(timing)
    return timing * 6
end

function M.default_gap(timing, step_count)
    return idiv(M.total_ticks(timing), step_count)
end

function M.implied_last_gap(timing, gaps)
    local total = M.total_ticks(timing)
    for _, gap in ipairs(gaps) do
        total = total - gap
    end
    return total
end

local function gcd(a, b)
    a = math.abs(a)
    b = math.abs(b)
    while b ~= 0 do
        a, b = b, a % b
    end
    return a
end

local function limit_denominator(numerator, denominator, max_denominator)
    local g = gcd(numerator, denominator)
    numerator = idiv(numerator, g)
    denominator = idiv(denominator, g)

    if denominator <= max_denominator then
        return numerator, denominator
    end

    local p0, q0, p1, q1 = 0, 1, 1, 0
    local n, d = numerator, denominator

    while true do
        local a = idiv(n, d)
        local q2 = q0 + a * q1
        if q2 > max_denominator then
            break
        end
        p0, q0, p1, q1 = p1, q1, p0 + a * p1, q2
        n, d = d, n - a * d
    end

    local k = idiv(max_denominator - q0, q1)
    local bound1_num = p0 + k * p1
    local bound1_den = q0 + k * q1
    local bound2_num = p1
    local bound2_den = q1

    local diff1 = math.abs(bound1_num * denominator - numerator * bound1_den)
    local diff2 = math.abs(bound2_num * denominator - numerator * bound2_den)

    if diff2 * bound1_den <= diff1 * bound2_den then
        return bound2_num, bound2_den
    end
    return bound1_num, bound1_den
end

function M.tick_label(ticks, timing)
    local total = M.total_ticks(timing)
    if total > 0 then
        local num, den = limit_denominator(ticks, total, 16)
        local frac
        if den == 1 then
            frac = tostring(num)
        else
            frac = string.format("%d/%d", num, den)
        end
        return string.format("%dt (%s)", ticks, frac)
    end
    return string.format("%dt", ticks)
end

local Step = {}
Step.__index = Step

function Step.new(code, gap)
    return setmetatable({
        code = code,
        gap = gap,
    }, Step)
end

local Entry = {}
Entry.__index = Entry

function Entry:_compute_min_safe_sc()
    local rb = self.rest_body
    local max_ref = 0
    local i = 0
    while i + 3 <= #rb do
        local b0 = byte_at(rb, i)
        local b1 = byte_at(rb, i + 1)
        if (b0 == 0x43 or b0 == 0x44) and b1 == 0x02 then
            local idx = byte_at(rb, i + 2)
            if idx > max_ref then
                max_ref = idx
            end
            i = i + 14
        else
            i = i + 2
        end
    end
    if max_ref > 0 then
        return max_ref
    end
    return 1
end

function Entry:_compute_anim_indexed_step_types()
    local rb = self.rest_body
    local indices = {}
    local i = 0
    while i + 3 <= #rb do
        local b0 = byte_at(rb, i)
        local b1 = byte_at(rb, i + 1)
        if (b0 == 0x43 or b0 == 0x44) and b1 == 0x02 then
            indices[#indices + 1] = byte_at(rb, i + 2)
            i = i + 14
        else
            i = i + 2
        end
    end

    if #indices == 0 then
        return {}
    end

    local result = {}
    local seen = {}
    for _, idx in ipairs(indices) do
        if not seen[idx] then
            seen[idx] = true
            if idx < #self.steps then
                result[idx] = self.steps[idx + 1]
            end
        end
    end
    return result
end

function Entry:get_anim_indices()
    local out = {}
    for idx in pairs(self.anim_indexed_step_types) do
        out[#out + 1] = idx
    end
    table.sort(out)
    return out
end

function Entry:as_step_list()
    local out = {}
    for i, code in ipairs(self.steps) do
        local gap = self.hits[i] or 0
        out[#out + 1] = Step.new(code, gap)
    end
    return out
end

function Entry.new(name, dp, np, ptr_off, sc, steps, timing, hits, raw, flag, orig_term, ff_prefix_count, rest_body)
    local self = setmetatable({
        name = name,
        base = M.base_name(name),
        dp = dp,
        np = np,
        ptr_off = ptr_off,
        sc = sc,
        steps = steps,
        timing = timing,
        hits = hits,
        raw = raw,
        flag = flag,
        orig_term = orig_term,
        start_delay = M.decode_start_delay(sc, orig_term),
        ff_prefix_count = ff_prefix_count,
        rest_body = rest_body,
    }, Entry)

    self.min_safe_sc = self:_compute_min_safe_sc()
    self.anim_indexed_step_types = self:_compute_anim_indexed_step_types()
    return self
end

function M.parse(buf)
    local b = normalize_buffer(buf)
    if slice(b, 0, 4) ~= "DGSH" then
        error("Not a DGSH file")
    end

    local pt = M.u32(b, 0x18 + 6 * 4)
    local cnt = M.u16(b, 0x08 + 6 * 2)
    local temp = {}

    for i = 0, cnt - 1 do
        local dp = M.u32(b, pt + i * 8)
        local np = M.u32(b, pt + i * 8 + 4)
        local name = read_c_string_ascii_ignore(b, np)

        if name ~= "" and #name >= 2 then
            if dp < #b and dp + 20 <= #b then
                local sc = M.u16(b, dp + 16)
                local timing = M.u16(b, dp + 18)
                if sc ~= 0 and sc <= 1024 then
                    local steps = bytes_to_list(slice(b, dp + 20, dp + 20 + sc))
                    local tl = M.term_len(sc)
                    local term_off = dp + 20 + sc
                    local orig_term = slice(b, term_off, term_off + tl)
                    local h_off = term_off + tl

                    if sc % 2 ~= 0 and term_off + 4 <= #b then
                        local looks_shifted_delay =
                            byte_at(orig_term, 0) ~= 0 and
                            byte_at(orig_term, 1) == 0 and
                            ({
                                [0x06] = true,
                                [0x0C] = true,
                                [0x12] = true,
                                [0x18] = true,
                                [0x30] = true,
                                [0x48] = true,
                                [0x60] = true,
                            })[byte_at(b, term_off + 2)] and
                            byte_at(b, term_off + 3) == 0

                        if looks_shifted_delay then
                            orig_term = string.char(0) .. slice(b, term_off, term_off + 2)
                            h_off = term_off + 2
                        end
                    end

                    if h_off + 2 <= #b then
                        local n_hits = math.max(sc - 1, 0)
                        local hits = {}
                        if n_hits > 0 then
                            for j = 0, n_hits - 1 do
                                hits[#hits + 1] = M.u16(b, h_off + j * 2)
                            end
                        end

                        local m_off = h_off + n_hits * 2
                        if m_off < #b then
                            temp[#temp + 1] = {
                                name = name,
                                dp = dp,
                                np = np,
                                ptr_off = pt + i * 8,
                                sc = sc,
                                steps = steps,
                                timing = timing,
                                hits = hits,
                                m_off = m_off,
                                row = i,
                                raw = slice(b, dp, dp + 12),
                                flag = slice(b, dp + 12, dp + 14),
                                orig_term = orig_term,
                            }
                        end
                    end
                end
            end
        end
    end

    table.sort(temp, function(a, c)
        if a.dp == c.dp then
            return a.row < c.row
        end
        return a.dp < c.dp
    end)

    local out = {}
    for _, t in ipairs(temp) do
        local rest = slice(b, t.m_off, t.np)
        local ff_count = 0
        for i = 1, #rest do
            if string.byte(rest, i) == 0xFF then
                ff_count = ff_count + 1
            else
                break
            end
        end

        if ff_count % 2 ~= 0 then
            print(string.format("[warn] odd ff_count in %s: %d", t.name, ff_count))
        end

        local rest_body = slice(rest, ff_count, #rest)
        out[#out + 1] = Entry.new(
            t.name,
            t.dp,
            t.np,
            t.ptr_off,
            t.sc,
            t.steps,
            t.timing,
            t.hits,
            t.raw,
            t.flag,
            t.orig_term,
            ff_count,
            rest_body
        )
    end

    return out
end

function M.local_id_list_info(entry)
    local rb = entry.rest_body
    local pos
    for i = 0, math.min(#rb - 2, 30) do
        if byte_at(rb, i) == 0x4F and byte_at(rb, i + 1) == 0x07 then
            pos = i
            break
        end
    end

    if pos == nil or pos <= 0 or (pos % 2) ~= 0 then
        return nil
    end

    local expected = math.max(entry.sc - 1, 0) * 2
    if pos ~= expected then
        return nil
    end

    local ids = {}
    for i = 0, pos - 2, 2 do
        ids[#ids + 1] = M.u16(rb, i)
    end

    if #ids == 0 then
        return nil
    end
    return pos, ids
end

M.Step = Step
M.Entry = Entry

return M
