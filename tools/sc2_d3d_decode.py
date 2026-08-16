"""Decompressor for StarCraft II's D3D shader cache
(mods/core.sc2mod/base.sc2data/versions/shaders41359/baselinecache.bin).

The D3D cache stores each shader as a Blizzard-proprietary *static-Huffman*
compressed **D3D9 Shader-Model-3 token stream** (ps_3_0 / vs_3_0).  The codec is
reversed statically from the macOS client `sc2.i64`:

  * ShaderCodecMgr_DeserializeTables @ 0x102b72400 lays out the pre-blob region
    (file bytes 0xA0 .. blob_start):
        6 manager tables (u16 count, u16 sym)
        1 codec TYPE byte  (1 => D3D9 SM3 Type1 codec)
        Type1 codec tables (loaded by codec vtable[72] = 0x102b858d0):
            7 global Huffman trees, then up to 98 per-opcode entries
        1 trailing manager table (u16 count, u8 sym)
    ...and the whole thing tiles EXACTLY to blob_start.
  * Four table-reader variants (all share one canonical-code generator):
        ShaderHuffman_DeserializeTable      @0x102b72610  count u16, sym u16
        ShaderHuffman_DeserializeTable_Last @0x102b72d60  count u16, sym u8
        sub_102B85BC0                       @0x102b85bc0  count u32, sym u16
        sub_102B862E0                       @0x102b862e0  count u8,  sym u8
    Wire per table: [count][ count x ([u8 codeLen][sym]) ], with count==0 =>
    header only, count==1 => header + one symbol (code length 0, no len byte).
  * Canonical codes are assigned by a bit-reversed increment and read LSB-first
    (decompress driver @0x102b846f0), so we replay the increment into a trie and
    decode LSB-first.

This module (Phase 1) provides the Huffman layer + region parse; the per-opcode
D3D9 token emission (driver + 21 operand handlers) is layered on top.
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
D3D_CACHE = os.path.join(REPO, "mods", "core.sc2mod", "base.sc2data",
                         "versions", "shaders41359", "baselinecache.bin")

PRE_BLOB_START = 0xA0   # region a2 passed to ShaderCodecMgr_DeserializeTables


# ---------------------------------------------------------------------------
# Static-Huffman table wire format + canonical decoder
# ---------------------------------------------------------------------------

def read_table(buf, off, cw, sw):
    """Read one serialized Huffman table.  `cw`/`sw` = count/symbol width in
    bytes.  Returns (entries, consumed) where entries is a list of (codeLen,
    symbol) in file order.  Mirrors the four DeserializeTable* variants."""
    count = int.from_bytes(buf[off:off + cw], "little")
    p = off + cw
    if count == 0:
        return [], cw
    if count == 1:
        sym = int.from_bytes(buf[p:p + sw], "little")
        return [(0, sym)], cw + sw          # single symbol, zero-length code
    entries = []
    for _ in range(count):
        ln = buf[p]
        sym = int.from_bytes(buf[p + 1:p + 1 + sw], "little")
        p += 1 + sw
        entries.append((ln, sym))
    return entries, p - off


class Huff:
    """Canonical static-Huffman decoder matching the client's tree builder.

    The builder assigns codes with a bit-reversed increment (the `_bittest`/xor
    loop shared by every DeserializeTable* variant) and the decompressor reads
    bits LSB-first, so we replay the increment and insert each code LSB-first
    into a binary trie."""

    __slots__ = ("single", "root", "nsym")

    def __init__(self, entries):
        self.nsym = len(entries)
        self.single = None
        self.root = None
        if not entries:
            return
        if len(entries) == 1 and entries[0][0] == 0:
            self.single = entries[0][1]          # zero-length code
            return
        # trie node = [child0, child1, sym]; sym is None on internal nodes
        self.root = [None, None, None]
        code = 0
        prev_len = None
        for i, (ln, sym) in enumerate(entries):
            if i > 0:
                j = prev_len - 1
                bit = 1 << j
                if code & (1 << j):
                    while True:
                        code ^= bit
                        bit >>= 1
                        if not (bit & code):
                            break
                code = bit | code
            # insert (ln, code) -> sym, reading code bits LSB-first
            node = self.root
            for k in range(ln):
                b = (code >> k) & 1
                nxt = node[b]
                if nxt is None:
                    nxt = [None, None, None]
                    node[b] = nxt
                node = nxt
            node[2] = sym
            prev_len = ln

    def empty(self):
        return self.nsym == 0

    def decode(self, br):
        """Decode one symbol from BitReader `br`."""
        if self.single is not None:
            return self.single
        node = self.root
        while node[2] is None:
            node = node[br.bit()]
        return node[2]


# ---------------------------------------------------------------------------
# Codec table set (Type1) + manager region parse
# ---------------------------------------------------------------------------

# 7 global Type1 tables, in the order 0x102b858d0 loads them (count_w, sym_w)
_T1_GLOBAL = [(2, 2), (2, 2), (2, 1), (2, 1), (2, 2), (2, 1), (2, 2)]
_N_OPCODES = 0x62  # 98


def parse_codec_tables(buf, pos):
    """Parse the Type1 codec tables starting at `pos` (just past the type byte).
    Returns (tables_dict, new_pos)."""
    g = []
    for cw, sw in _T1_GLOBAL:
        e, c = read_table(buf, pos, cw, sw)
        g.append(Huff(e))
        pos += c
    opcodes = {}
    for op in range(_N_OPCODES):
        cnt = int.from_bytes(buf[pos:pos + 4], "little")
        if cnt == 0:
            pos += 4
            continue
        e0, c = read_table(buf, pos, 4, 2)   # sub_102B85BC0
        pos += c
        e1, c = read_table(buf, pos, 2, 2)   # ShaderHuffman_DeserializeTable
        pos += c
        e2, c = read_table(buf, pos, 1, 1)   # sub_102B862E0
        pos += c
        opcodes[op] = (Huff(e0), Huff(e1), Huff(e2))
    return {"global": g, "opcodes": opcodes}, pos


def parse_pre_blob_region(data, blob_start, region_start=PRE_BLOB_START,
                          verbose=False):
    """Parse the whole pre-blob table region and return (codec_tables,
    manager_tables).  Asserts the region tiles exactly to blob_start."""
    pos = region_start
    mgr = []
    for _ in range(6):                       # 6 manager tables (u16,u16)
        e, c = read_table(data, pos, 2, 2)
        mgr.append(Huff(e))
        if verbose:
            print("  mgr table  nsym=%d  consumed=%d  end=%d" % (len(e), c, pos + c))
        pos += c
    type_byte = data[pos]
    pos += 1
    if verbose:
        print("  codec TYPE byte = %d  (@%d)" % (type_byte, pos - 1))
    assert type_byte == 1, "expected Type1 (D3D9 SM3) codec, got %d" % type_byte
    codec, pos = parse_codec_tables(data, pos)
    if verbose:
        print("  codec: 7 global + %d/%d per-opcode entries  end=%d"
              % (len(codec["opcodes"]), _N_OPCODES, pos))
    e, c = read_table(data, pos, 2, 1)       # trailing manager table (_Last)
    mgr.append(Huff(e))
    pos += c
    if verbose:
        print("  trailing mgr table  nsym=%d  end=%d  (blob_start=%d)"
              % (len(e), pos, blob_start))
    assert pos == blob_start, \
        "table region ended at %d, expected blob_start %d" % (pos, blob_start)
    return codec, mgr


# ---------------------------------------------------------------------------
# Bit reader (matches the client's mask walk: LSB-first, bit0 of byte0 is the
# ps/vs type bit so the Huffman stream starts at mask=2)
# ---------------------------------------------------------------------------

class BitReader:
    __slots__ = ("data", "pos", "mask")

    def __init__(self, data, start_mask=2):
        self.data = data
        self.pos = 0
        self.mask = start_mask

    def bit(self):
        b = 1 if (self.data[self.pos] & self.mask) else 0
        if self.mask == 0x80:
            self.mask = 1
            self.pos += 1
        else:
            self.mask <<= 1
        return b

    def consumed_bytes(self):
        # bytes fully or partially consumed (matches driver's return value)
        return self.pos + (1 if self.mask != 1 else 0)


# ---------------------------------------------------------------------------
# Operand-token decode  (sub_102B86F80 dest / sub_102B87220 src / 87BE0 rel)
# ---------------------------------------------------------------------------

def _decode_relative(codec, br, want_swizzle):
    """Relative-address token (sub_102B87BE0 / inline in 86F80)."""
    tok = codec["global"][4].decode(br) | 0x80000000
    rt = 15 if br.bit() else 3                 # LOOP(aL) vs ADDR(a0)
    tok |= ((rt << 28) | (rt << 8)) & 0x70000800
    if want_swizzle:
        tok |= codec["global"][5].decode(br) << 16
    return tok & 0xFFFFFFFF


def decode_operand(codec, br, op, shape, is_dest, desc):
    """Decode one dst/src parameter token (+ optional relative token)."""
    t0, t1, t2 = codec["opcodes"][op]
    regsym = t0.decode(br)
    rtype = (regsym >> 11) if shape > 0x13 else shape
    regnum = regsym & 0x7FF
    tok = 0x80000000 | ((rtype & 7) << 28) | ((rtype & 0x18) << 8) | regnum
    hw = (t2 if is_dest else t1).decode(br)
    tok = (tok | (hw << 16)) & 0xFFFFFFFF
    out = [tok]
    if is_dest:
        gated = desc["type"] == 0              # dest relative: VS only
    else:
        gated = desc["type"] == 0 or desc["major"] >= 3
    if gated and br.bit():
        out[0] = tok | 0x2000                  # relative-address flag (bit13)
        out.append(_decode_relative(codec, br, want_swizzle=not is_dest))
    return out


# ---------------------------------------------------------------------------
# Per-opcode operand shapes (D3D9 opcode index -> operand sequence)
# ---------------------------------------------------------------------------

_ALU1 = {1, 6, 7, 14, 15, 16, 19, 35, 36, 46, 78, 79, 91, 92}   # dst + 1 src
_ALU2 = {2, 3, 5, 8, 9, 10, 11, 12, 13, 17, 32, 33, 89}         # dst + 2 src
_ALU3 = {4, 18, 80, 88, 90}                                     # dst + 3 src


def emit_instruction(codec, br, op, desc):
    """Decode all parameter tokens for opcode `op`; returns a token list."""
    p = []

    def dst(shape=0x14):
        p.extend(decode_operand(codec, br, op, shape, True, desc))

    def src(shape=0x14):
        p.extend(decode_operand(codec, br, op, shape, False, desc))

    def bytes_dword(tbl, n):
        for _ in range(n):
            b = [tbl.decode(br) for _ in range(4)]
            p.append(b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24))

    G = codec["global"]
    if op in _ALU1:
        dst(); src()
    elif op in _ALU2:
        dst(); src(); src()
    elif op in _ALU3:
        dst(); src(); src(); src()
    elif op == 31:                              # DCL: usage dword + reg
        b = [G[2].decode(br) for _ in range(4)]
        p.append(b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24))
        dst()
    elif op == 81:                              # DEF c#, f0..f3
        dst(0x14); bytes_dword(G[3], 4)
    elif op == 48:                              # DEFI i#, i0..i3
        dst(7); bytes_dword(G[2], 4)
    elif op == 47:                              # DEFB b#, bool
        dst(0x0E); p.append(1 if br.bit() else 0)
    elif op == 37:                              # SINCOS (ps_3_0: dst + 1 src)
        dst(0); src()
        if desc["major"] <= 2:
            src(); src()
    elif op == 38:                              # REP i#
        src(7)
    elif op == 27:                              # LOOP aL, i#
        src(0x0F); src(7)
    elif op in (41, 45):                        # IFC / BREAKC
        src(); src()
    elif op == 65 or op == 87:                  # TEXKILL / TEXDEPTH
        dst()
    elif op == 66:                              # TEXLD dst, coord, s#
        dst(); src(); src(0x0A)
    elif op in (83, 85):                        # TEXDP3TEX / TEXDP3
        dst(); src()
    elif op == 95:                              # TEXLDL dst, coord, s#
        dst(); src(); src(0x0A)
    elif op == 93:                              # TEXLDD dst, coord, s#, dsx, dsy
        dst(); src(); src(0x0A); src(); src()
    else:
        raise NotImplementedError("opcode %d has a per-opcode table but no "
                                  "operand shape mapping" % op)
    return p


# ---------------------------------------------------------------------------
# Decompress driver  (sub_102B846F0)
# ---------------------------------------------------------------------------

def decompress_code(codec, comp, n_tokens):
    """Decompress the Huffman code region `comp` into `n_tokens` D3D9 tokens."""
    br = BitReader(comp)
    type_bit = comp[0] & 1                      # 1=pixel, 0=vertex
    ver_hi = ((0xFFFFFFFE | type_bit) << 16) & 0xFFFFFFFF
    desc = {"type": type_bit}
    vtbl = codec["global"][0]
    vsym = vtbl.decode(br) if not vtbl.empty() else 0x0300
    desc["minor"] = vsym & 0xFF
    desc["major"] = (vsym >> 8) & 0xFF
    out = [ver_hi | vsym]
    optbl = codec["global"][1]
    while len(out) < n_tokens - 1:
        opsym = optbl.decode(br)
        control = (opsym >> 7) & 0xFF
        opidx = opsym & 0x7F
        d3dop = 0xFFFD if opidx == 97 else opidx
        pos = len(out)
        out.append(d3dop | (control << 16))
        if opidx in codec["opcodes"]:
            params = emit_instruction(codec, br, opidx, desc)
        else:
            params = []                         # zero-operand opcode
        out.extend(params)
        out[pos] = (out[pos] | (len(params) << 24)) & 0xFFFFFFFF
    out.append(0xFFFF)                          # D3DSIO_END
    return out, desc, br.consumed_bytes()


# ---------------------------------------------------------------------------
# Blob framing + top-level cache access
# ---------------------------------------------------------------------------

def parse_blob_header(blob):
    """[u8 dedup][u32 hash][u16 codeSize>>2][u16 metaSize] then code+meta."""
    dedup = blob[0]
    hsh = struct.unpack_from("<I", blob, 1)[0]
    n_tokens = struct.unpack_from("<H", blob, 5)[0]
    meta_size = struct.unpack_from("<H", blob, 7)[0]
    return dedup, hsh, n_tokens, meta_size


class D3DCache:
    """Loads the codec tables once; decodes any blob to a D3D9 token stream."""

    def __init__(self, path=D3D_CACHE):
        self.data = open(path, "rb").read()
        assert self.data[0x10:0x14] == b"MSER"
        self.blob_start = struct.unpack_from("<I", self.data, 0x20)[0]
        self.codec, self.mgr = parse_pre_blob_region(self.data, self.blob_start)
        self._by_hash = {}                      # hash -> token list (dedup refs)

    def decode_blob(self, blob_off, blob_size):
        blob = self.data[blob_off:blob_off + blob_size]
        dedup, hsh, n_tokens, meta_size = parse_blob_header(blob)
        if dedup:
            if hsh in self._by_hash:
                return self._by_hash[hsh], None
            return None, "dedup-ref to unseen hash %08x" % hsh
        tokens, desc, used = decompress_code(self.codec, blob[9:], n_tokens)
        self._by_hash[hsh] = tokens
        return tokens, desc


def tokens_to_bytes(tokens):
    return b"".join(struct.pack("<I", t & 0xFFFFFFFF) for t in tokens)


def _main():
    cache = D3DCache()
    print("blob_start=%d  codec: 7 global + %d per-opcode"
          % (cache.blob_start, len(cache.codec["opcodes"])))
    import sc2_cache
    _d, _v, records = sc2_cache.parse_cache(D3D_CACHE)
    import sc2_ps_layout as L
    n_ok = n_dedup = n_fail = 0
    samples = []
    for r in records:
        (_h0, _h1), vec = sc2_cache.decode_key(r["key"])
        fam = L.family_of(vec)
        if not fam or fam[0] != "Model":
            continue
        toks, desc = cache.decode_blob(r["blob_off"], r["blobsize"])
        if toks is None:
            n_dedup += 1
            continue
        if len(samples) < 3:
            samples.append((r, toks, desc))
        n_ok += 1
        if n_ok >= 400:
            break
    print("decoded ok=%d  dedup=%d" % (n_ok, n_dedup))
    for r, toks, desc in samples:
        print("\n--- blob_off=%d size=%d  ver=%s  tokens=%d  head=%s END=%08x"
              % (r["blob_off"], r["blobsize"], desc and (desc["major"], desc["minor"]),
                 len(toks), "%08x" % toks[0], toks[-1]))


if __name__ == "__main__":
    _main()
