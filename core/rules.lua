local format = require("core.format")

local M = {}

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

function M.detect_rescue_section(entry)
    local prefix_len, ids = format.local_id_list_info(entry)
    if prefix_len == nil then
        return nil
    end

    return {
        prefix_len = prefix_len,
        ids = copy_list(ids),
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
                if required_code ~= nil and target_step ~= nil and target_step.code ~= required_code then
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
