#!/usr/bin/env python3
import struct

from sc5_format import (
    u16, u32, w32,
    local_id_list_info,
)

def encode_start_delay(step_count, delay_ticks):
    """Encode start delay for the current step-count parity."""
    delay_ticks = max(0, min(int(delay_ticks), 0xFFFF))
    if step_count % 2:
        return b"\x00" + struct.pack("<H", delay_ticks)
    return struct.pack("<H", delay_ticks)

COMMON_GAP_LO_BYTES = {0x06, 0x0C, 0x12, 0x18, 0x30, 0x48, 0x60}

def find_shifted_start_delay_entries(buf):
    """
    Find files produced by the broken start-delay build.

    Bad odd-step layout:
        steps + u16(delay) + hit gaps

    Correct odd-step layout:
        steps + 00 + u16(delay) + hit gaps

    The bad layout is missing a padding byte, which would cause the patcher (and game) to read garbage data.
    """
    b = bytearray(buf)
    if b[:4] != b"DGSH":
        return []
    pt  = u32(b, 0x18 + 6 * 4)
    cnt = u16(b, 0x08 + 6 * 2)
    found = []
    for i in range(cnt):
        dp = u32(b, pt + i * 8)
        np_ = u32(b, pt + i * 8 + 4)
        if dp >= len(b) or dp + 24 > len(b):
            continue
        sc = u16(b, dp + 16)
        if sc == 0 or sc > 1024 or sc % 2 == 0:
            continue
        term_off = dp + 20 + sc
        if term_off + 4 > len(b):
            continue
        looks_shifted = (
            b[term_off] != 0 and
            b[term_off + 1] == 0 and
            b[term_off + 2] in COMMON_GAP_LO_BYTES and
            b[term_off + 3] == 0
        )
        if looks_shifted:
            e = np_
            while e < len(b) and b[e]:
                e += 1
            name = b[np_:e].decode("ascii", "ignore")
            found.append((name, term_off))
    return found


def normalize_shifted_start_delay_layout(buf):
    """
    Insert the missing odd-step alignment byte for any shifted start-delay
    entries, then relocate all DGSH pointers and update file size.
    """
    repairs = find_shifted_start_delay_entries(buf)
    if not repairs:
        return bytes(buf), []

    data = bytearray(buf)
    shift = 0
    repaired_names = []
    for name, original_pos in repairs:
        pos = original_pos + shift
        data[pos:pos] = b"\x00"
        repaired_names.append(name)

        pt  = u32(data, 0x18 + 6 * 4)
        cnt = u16(data, 0x08 + 6 * 2)
        for i in range(cnt):
            off = pt + i * 8
            for j in range(2):
                p = off + j * 4
                v = u32(data, p)
                if v >= pos:
                    w32(data, p, v + 1)

        for i in range(8):
            o = 0x18 + i * 4
            v = u32(data, o)
            if v and v >= pos:
                w32(data, o, v + 1)

        shift += 1

    w32(data, 0x04, len(data))
    return bytes(data), repaired_names

def expand_local_id_list_if_needed(entry, rest_body, new_step_count):
    """
    Expand/truncate PS007-style local ID prefixes to match a changed step count.

    Target ID count is new_step_count - 1.  When expanding, repeat the original
    ID list cyclically: [0x77, 0x52] -> [0x77, 0x52, 0x77, 0x52].
    """
    info = local_id_list_info(entry)
    if info is None:
        return rest_body

    prefix_len, ids = info
    target_count = max(new_step_count - 1, 0)
    if target_count == len(ids):
        return rest_body

    new_prefix = bytearray()
    if target_count:
        for i in range(target_count):
            new_prefix += struct.pack("<H", ids[i % len(ids)])

    return bytes(new_prefix) + bytes(rest_body[prefix_len:])

def rebuild(entry, new_steps_list, new_anim_indices=None, start_delay=None):
    """
    Rebuild an entry with new steps and optionally new animation indices.
    
    new_anim_indices: list of step indices (0-based) that animation blocks should reference.
                     Must be same length as original anim indices, or None to keep unchanged.
    start_delay: lead-in delay in ticks. If None, uses the entry's original value.
    """
    codes    = [s.code for s in new_steps_list]
    new_hits = [s.gap  for s in new_steps_list[:-1]]
    N        = len(codes)
    total    = entry.timing

    # Bytes after the visible step list are a start-delay / lead-in field, not
    # disposable padding. Encoding depends on step-count parity:
    #   odd sc:  00 + u16 delay
    #   even sc: u16 delay
    if start_delay is None:
        start_delay = entry.start_delay
    new_term = encode_start_delay(N, start_delay)

    # raw[8:10] is NOT always the visible step count.
    # For example, see FIX blocks i.e. r11's ps007-ps017 blocks.
    buf  = bytearray(entry.raw)
    if local_id_list_info(entry) is None:
        struct.pack_into("<H", buf, 8, N)
    buf += entry.flag
    buf += bytes([0x31, ((5 * N + 7) >> 1) & 0xFF])
    buf += struct.pack("<H", N)
    buf += struct.pack("<H", total)
    buf += bytes(codes)
    buf += new_term

    for h in new_hits:
        buf += struct.pack("<H", h)

    orig_sc = entry.sc
    orig_ff = entry.ff_prefix_count
    if orig_ff == orig_sc * 2:
        new_ff_prefix = b'\xff\xff' * N
    else:
        new_ff_prefix = b'\xff' * orig_ff

    # Rewrite animation indices in rest_body if requested
    rest_body = bytearray(entry.rest_body)
    if new_anim_indices is not None:
        orig_indices = entry.get_anim_indices()
        if len(new_anim_indices) != len(orig_indices):
            raise ValueError(f"new_anim_indices must have {len(orig_indices)} elements")
        
        index_map = dict(zip(orig_indices, new_anim_indices))
        
        i = 0
        while i + 3 <= len(rest_body):
            if rest_body[i] in (0x43, 0x44) and rest_body[i + 1] == 0x02:
                old_idx = rest_body[i + 2]
                if old_idx in index_map:
                    rest_body[i + 2] = index_map[old_idx]
                i += 14
            else:
                i += 2

    rest_body = expand_local_id_list_if_needed(entry, bytes(rest_body), N)

    buf += new_ff_prefix + bytes(rest_body)
    return bytes(buf)

def apply(buf, entries, mods):
    data  = bytearray(buf)
    shift = 0
    for e in entries:
        if e.name not in mods:
            continue
        mod = mods[e.name]
        if isinstance(mod, tuple):
            if len(mod) == 3:
                new_steps_list, new_anim_indices, start_delay = mod
            else:
                new_steps_list, new_anim_indices = mod
                start_delay = None
        else:
            # Backward compatibility with older in-memory mods.
            new_steps_list, new_anim_indices, start_delay = mod, None, None
        new_block = rebuild(e, new_steps_list, new_anim_indices, start_delay)
        old_start = e.dp + shift
        old_end   = e.np + shift
        old_size  = old_end - old_start
        new_size  = len(new_block)
        delta     = new_size - old_size
        data      = bytearray(data[:old_start] + new_block + data[old_end:])
        shift    += delta
        pt  = u32(data, 0x18 + 6 * 4)
        cnt = u16(data, 0x08 + 6 * 2)
        for i in range(cnt):
            off = pt + i * 8
            for j in range(2):
                p = off + j * 4
                v = u32(data, p)
                if v >= old_end:
                    w32(data, p, v + delta)
        for i in range(8):
            o = 0x18 + i * 4
            v = u32(data, o)
            if v and v >= old_end:
                w32(data, o, v + delta)
        w32(data, e.ptr_off + 4, e.dp + shift + (new_size - delta))
    w32(data, 0x04, len(data))
    return bytes(data)
