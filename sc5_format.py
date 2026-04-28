#!/usr/bin/env python3
import struct
import re

GAME_TO_INTERNAL = {"UP": 3, "RIGHT": 4, "DOWN": 5, "LEFT": 6}
INTERNAL_TO_GAME = {v: k for k, v in GAME_TO_INTERNAL.items()}
MOVES = {0: "REST", 1: "CHU", 2: "HEY", 3: "LEFT", 4: "UP",
         5: "RIGHT", 6: "DOWN", 9: "HOLDCHU", 10: "HOLDHEY",
         11: "HOLDUP", 12: "HOLDRIGHT", 13: "HOLDDOWN", 14: "HOLDLEFT"}
INV = {v: k for k, v in MOVES.items()}

def u16(b, o): return struct.unpack_from("<H", b, o)[0]
def u32(b, o): return struct.unpack_from("<I", b, o)[0]
def w32(b, o, v): struct.pack_into("<I", b, o, v)
def term_len(n): return 3 if n % 2 else 2

def decode_start_delay(step_count, term_bytes):
    """Decode the lead-in/start-delay field after the step bytes.

    Odd step counts store one alignment byte, then a u16 delay.
    Even step counts store just the u16 delay.
    """
    if step_count % 2:
        if len(term_bytes) >= 3:
            return u16(term_bytes, 1)
        return 0
    if len(term_bytes) >= 2:
        return u16(term_bytes, 0)
    return 0


def base_name(name): return re.sub(r'[a-z]$', '', name)

def is_raw_byte(code):
    """True if this step code is not a named move (arbitrary byte)."""
    return code not in MOVES and code not in INTERNAL_TO_GAME

def step_display_name(code):
    name = INTERNAL_TO_GAME.get(code, MOVES.get(code))
    if name:
        return name
    return f"0x{code:02X}"

TICK_CYCLE = [6, 12, 18, 24, 48, 72]

def total_ticks(timing):
    return timing * 6

def default_gap(timing, sc):
    return total_ticks(timing) // sc

def implied_last_gap(timing, gaps):
    return total_ticks(timing) - sum(gaps)

def tick_label(ticks, timing):
    total = total_ticks(timing)
    if total > 0:
        from fractions import Fraction
        f = Fraction(ticks, total).limit_denominator(16)
        return f"{ticks}t ({f})"
    return f"{ticks}t"

class Step:
    def __init__(self, code, gap):
        self.code = code
        self.gap  = gap

class Entry:
    def __init__(self, name, dp, np_, ptr_off, sc, steps, timing, hits, raw, flag, orig_term,
                 ff_prefix_count, rest_body):
        self.name      = name
        self.base      = base_name(name)
        self.dp        = dp
        self.np        = np_
        self.ptr_off   = ptr_off
        self.sc        = sc
        self.steps     = steps
        self.timing    = timing
        self.hits      = hits
        self.raw       = raw
        self.flag      = flag
        self.orig_term = orig_term
        self.start_delay = decode_start_delay(sc, orig_term)
        self.ff_prefix_count = ff_prefix_count
        self.rest_body       = rest_body
        self.min_safe_sc     = self._compute_min_safe_sc()
        self.anim_indexed_step_types = self._compute_anim_indexed_step_types()

    def _compute_min_safe_sc(self):
        """
        Scan rest_body for 0x4302 / 0x4402 animation blocks.
        Byte 2 of each block is a 1-based step index the engine will dereference.
        If sc < that index the engine reads past the step array -> hardlock.
        Returns the minimum sc that keeps all references valid (at least 1).
        """
        rb = self.rest_body
        max_ref = 0
        i = 0
        while i + 3 <= len(rb):
            if rb[i] in (0x43, 0x44) and rb[i + 1] == 0x02:
                idx = rb[i + 2]   # 1-based
                if idx > max_ref:
                    max_ref = idx
                i += 14           # fixed block size
            else:
                i += 2
        return max_ref if max_ref > 0 else 1

    def _compute_anim_indexed_step_types(self):
        """
        For entries with animation blocks (4302/4402), the game engine validates
        that the step type at each indexed position matches the expected type.
        Returns a dict {index: required_step_code} for all anim-referenced positions.
        Empty dict = no constraints (entry has no anim blocks).
        """
        rb = self.rest_body
        indices = []
        i = 0
        while i + 3 <= len(rb):
            if rb[i] in (0x43, 0x44) and rb[i + 1] == 0x02:
                indices.append(rb[i + 2])
                i += 14
            else:
                i += 2
        
        if not indices:
            return {}
        
        result = {}
        for idx in set(indices):
            if idx < len(self.steps):
                result[idx] = self.steps[idx]
        return result
    
    def get_anim_indices(self):
        """Return the list of unique step indices referenced by animation blocks."""
        return sorted(self.anim_indexed_step_types.keys())

    def as_step_list(self):
        out = []
        for i, code in enumerate(self.steps):
            gap = self.hits[i] if i < len(self.hits) else 0
            out.append(Step(code, gap))
        return out

def parse(buf):
    b = bytearray(buf)
    if b[:4] != b"DGSH":
        raise ValueError("Not a DGSH file")
    pt  = u32(b, 0x18 + 6 * 4)
    cnt = u16(b, 0x08 + 6 * 2)
    temp = []
    for i in range(cnt):
        dp  = u32(b, pt + i * 8)
        np_ = u32(b, pt + i * 8 + 4)
        e   = np_
        while e < len(b) and b[e]:
            e += 1
        name = b[np_:e].decode("ascii", "ignore")
        if not name or len(name) < 2:
            continue
        if dp >= len(b) or dp + 20 > len(b):
            continue
        sc     = u16(b, dp + 16)
        timing = u16(b, dp + 18)
        if sc == 0 or sc > 1024:
            continue
        steps     = list(b[dp + 20: dp + 20 + sc])
        tl        = term_len(sc)
        term_off  = dp + 20 + sc
        orig_term = bytes(b[term_off: term_off + tl])
        h_off     = term_off + tl

        # Repair files made by the older/broken start-delay logic.
        # For odd step counts the correct layout is:
        #     00 + u16(start_delay), then hit gaps
        # Except for that one FUCKING BUILD that used this:
        #     u16(start_delay), then hit gaps
        # which makes the parser read the first hit byte as part of the delay
        # and shifts every gap into nonsense values like 6144t / 65280t.
        # FUCK.
        if sc % 2 and term_off + 4 <= len(b):
            looks_shifted_delay = (
                orig_term[0] != 0 and
                orig_term[1] == 0 and
                b[term_off + 2] in (0x06, 0x0C, 0x12, 0x18, 0x30, 0x48, 0x60) and
                b[term_off + 3] == 0
            )
            if looks_shifted_delay:
                orig_term = b"\x00" + bytes(b[term_off:term_off + 2])
                h_off = term_off + 2

        if h_off + 2 > len(b):
            continue
        n_hits = max(sc - 1, 0)
        hits   = [u16(b, h_off + j * 2) for j in range(n_hits)] if n_hits else []
        m_off  = h_off + n_hits * 2
        if m_off >= len(b):
            continue
        temp.append(dict(
            name=name, dp=dp, np=np_, ptr_off=pt + i * 8,
            sc=sc, steps=steps, timing=timing, hits=hits, m_off=m_off,
            raw=bytes(b[dp: dp + 12]),
            flag=bytes(b[dp + 12: dp + 14]),
            orig_term=orig_term,
        ))
    temp.sort(key=lambda x: x["dp"])
    out = []
    for t in temp:
        rest = bytes(b[t["m_off"]: t["np"]])
        ff_count = 0
        for byte in rest:
            if byte == 0xFF:
                ff_count += 1
            else:
                break
        if ff_count % 2 != 0:
            print(f"[warn] odd ff_count in {t['name']}: {ff_count}")
        rest_body = rest[ff_count:]
        entry = Entry(
            t["name"], t["dp"], t["np"], t["ptr_off"],
            t["sc"], t["steps"], t["timing"], t["hits"],
            t["raw"], t["flag"], t["orig_term"],
            ff_count, rest_body
        )
        out.append(entry)

    return out

def local_id_list_info(entry):
    """
    Detect PS007-style local rescue/object ID lists.

    Some HEY-rescue entries keep a small u16 ID list at the start of rest_body,
    immediately followed by 0x4F07 event records. For example, PS007 has:

        77 00 52 00 4F 07 [...]

    Vanilla PS007 has 3 visible steps and 2 IDs.  If the visible step count is
    expanded without also expanding this local ID list, the game appears to read
    the following 4F07 event opcode as a bogus third ID and crashes.

    Returns (prefix_len, ids) where prefix_len is the byte length before 4F07,
    or None if this entry does not look like that format.
    """
    rb = entry.rest_body
    pos = rb.find(b"\x4f\x07", 0, 32)
    if pos <= 0 or (pos % 2):
        return None

    expected = max(entry.sc - 1, 0) * 2
    if pos != expected:
        return None

    ids = [u16(rb, i) for i in range(0, pos, 2)]
    if not ids:
        return None
    return pos, ids
