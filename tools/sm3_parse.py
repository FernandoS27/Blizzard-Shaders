"""Parser for Direct3D9 Shader-Model-3 token streams (ps_3_0 / vs_3_0).

Consumes EITHER:
  * a retail token list from sc2_d3d_decode.D3DCache.decode_blob (no CTAB), or
  * native `fxc /T ps_3_0 /Fo out` bytes (has a CTAB comment block).

Produces an `SM3Program` that the SM3 executor (sm3_exec) runs.  The token layout
follows the D3D9 shader-token spec:

  version token   : 0xFFFF|major<<8|minor (ps) / 0xFFFE... (vs)
  instruction tok : [15:0]=opcode  [23:16]=control  [27:24]=length  [28]=predicated
  comment tok     : [15:0]=0xFFFE  [30:16]=dword-count (CTAB lives here)
  end tok         : 0x0000FFFF
  param tok       : [31]=1  regtype=((t>>28)&7)|((t>>8)&0x18)  regnum=t&0x7FF
                    [13]=relative-addr  ; dst: [19:16]=writemask [23:20]=resultmod
                    src: [23:16]=swizzle [27:24]=srcmod
"""
import struct

# D3DSHADER_PARAM_REGISTER_TYPE
(RT_TEMP, RT_INPUT, RT_CONST, RT_ADDR, RT_RASTOUT, RT_ATTROUT, RT_OUTPUT,
 RT_CONSTINT, RT_COLOROUT, RT_DEPTHOUT, RT_SAMPLER, RT_CONST2, RT_CONST3,
 RT_CONST4, RT_CONSTBOOL, RT_LOOP, RT_TEMPFLOAT16, RT_MISCTYPE, RT_LABEL,
 RT_PREDICATE) = range(20)
RT_TEXTURE = RT_ADDR   # type 3 is ADDR in vs, TEXTURE in ps

REG_PREFIX = {RT_TEMP: "r", RT_INPUT: "v", RT_CONST: "c", RT_ADDR: "a",
              RT_OUTPUT: "o", RT_CONSTINT: "i", RT_COLOROUT: "oC",
              RT_DEPTHOUT: "oDepth", RT_SAMPLER: "s", RT_CONSTBOOL: "b",
              RT_LOOP: "aL", RT_MISCTYPE: "vMISC", RT_PREDICATE: "p",
              RT_RASTOUT: "oRast", RT_ATTROUT: "oAttr", RT_LABEL: "l"}

# operand roles per opcode (matches sc2_d3d_decode.emit_instruction shapes)
_DST_SRC = {
    1: ["d", "s"], 6: ["d", "s"], 7: ["d", "s"], 14: ["d", "s"],
    15: ["d", "s"], 16: ["d", "s"], 19: ["d", "s"], 35: ["d", "s"],
    36: ["d", "s"], 46: ["d", "s"], 91: ["d", "s"], 92: ["d", "s"],
    2: ["d", "s", "s"], 3: ["d", "s", "s"], 5: ["d", "s", "s"],
    8: ["d", "s", "s"], 9: ["d", "s", "s"], 10: ["d", "s", "s"],
    11: ["d", "s", "s"], 12: ["d", "s", "s"], 13: ["d", "s", "s"],
    17: ["d", "s", "s"], 32: ["d", "s", "s"], 33: ["d", "s", "s"],
    89: ["d", "s", "s"], 20: ["d", "s", "s"], 21: ["d", "s", "s"],
    22: ["d", "s", "s"], 23: ["d", "s", "s"], 24: ["d", "s", "s"],
    4: ["d", "s", "s", "s"], 18: ["d", "s", "s", "s"], 88: ["d", "s", "s", "s"],
    90: ["d", "s", "s", "s"], 34: ["d", "s", "s", "s"],
    27: ["s", "s"], 38: ["s"], 40: ["s"], 41: ["s", "s"], 45: ["s", "s"],
    65: ["d"], 87: ["d"], 66: ["d", "s", "s"], 83: ["d", "s"], 85: ["d", "s"],
    95: ["d", "s", "s"], 93: ["d", "s", "s", "s", "s"], 26: ["s"], 25: ["s"],
    30: ["s"], 37: ["d", "s"],           # sincos (ps_3_0 form; disasm only)
}
_ZERO = {0, 28, 29, 39, 42, 43, 44}   # nop ret endloop endrep else endif break

D3DSIO_NAME = {
    0: "nop", 1: "mov", 2: "add", 3: "sub", 4: "mad", 5: "mul", 6: "rcp",
    7: "rsq", 8: "dp3", 9: "dp4", 10: "min", 11: "max", 12: "slt", 13: "sge",
    14: "exp", 15: "log", 16: "lit", 17: "dst", 18: "lrp", 19: "frc",
    20: "m4x4", 21: "m4x3", 22: "m3x4", 23: "m3x3", 24: "m3x2", 25: "call",
    26: "callnz", 27: "loop", 28: "ret", 29: "endloop", 30: "label",
    31: "dcl", 32: "pow", 33: "crs", 34: "sgn", 35: "abs", 36: "nrm",
    37: "sincos", 38: "rep", 39: "endrep", 40: "if", 41: "ifc", 42: "else",
    43: "endif", 44: "break", 45: "breakc", 46: "mova", 47: "defb", 48: "defi",
    65: "texkill", 66: "texld", 81: "def", 83: "texdp3tex", 85: "texdp3",
    87: "texdepth", 88: "cmp", 89: "bem", 90: "dp2add", 91: "dsx", 92: "dsy",
    93: "texldd", 95: "texldl",
}

# D3DDECLUSAGE for dcl input semantics
USAGE_NAME = {0: "position", 1: "blendweight", 2: "blendindices", 3: "normal",
              4: "psize", 5: "texcoord", 6: "tangent", 7: "binormal",
              8: "tessfactor", 9: "positiont", 10: "color", 11: "fog",
              12: "depth", 13: "sample"}


class Operand:
    __slots__ = ("rtype", "num", "swizzle", "writemask", "srcmod", "dstmod",
                 "rel")

    def __init__(self, rtype, num):
        self.rtype = rtype
        self.num = num
        self.swizzle = 0xE4      # .xyzw identity (00 01 10 11)
        self.writemask = 0xF
        self.srcmod = 0
        self.dstmod = 0
        self.rel = None          # Operand of the relative address register

    def name(self):
        p = REG_PREFIX.get(self.rtype, "?%d" % self.rtype)
        if self.rtype in (RT_LOOP, RT_DEPTHOUT):
            return p
        return "%s%d" % (p, self.num)

    def __repr__(self):
        return "<%s>" % self.name()


class Instr:
    __slots__ = ("op", "name", "control", "predicated", "operands", "imm",
                 "usage", "usage_idx", "sampler_type")

    def __init__(self, op):
        self.op = op
        self.name = D3DSIO_NAME.get(op, "op%d" % op)
        self.control = 0
        self.predicated = False
        self.operands = []
        self.imm = None            # def/defi/defb immediate (list of 4 raw u32)
        self.usage = None          # dcl usage
        self.usage_idx = 0
        self.sampler_type = None   # dcl sampler texture dim

    def __repr__(self):
        return "<%s %s>" % (self.name, self.operands)


def _parse_param(tok):
    op = Operand(((tok >> 28) & 7) | ((tok >> 8) & 0x18), tok & 0x7FF)
    op.swizzle = (tok >> 16) & 0xFF
    op.writemask = (tok >> 16) & 0xF
    op.srcmod = (tok >> 24) & 0xF
    op.dstmod = (tok >> 20) & 0xF
    return op, bool((tok >> 13) & 1)


class SM3Program:
    def __init__(self):
        self.is_pixel = True
        self.major = 3
        self.minor = 0
        self.instrs = []
        self.defs = {}            # (rtype, num) -> [4 raw u32]
        self.inputs = {}          # v# num -> (usage, usage_idx)
        self.misc = {}            # vMISC num -> usage (0=vPos, 1=vFace)
        self.samplers = {}        # s# num -> texture dim (2=2d,3=vol,4=cube)
        self.outputs = set()      # colorout regs written
        self.ctab = None          # {name: (rtype, reg, count)} if present

    @classmethod
    def from_tokens(cls, tokens):
        p = cls()
        v0 = tokens[0]
        p.is_pixel = (v0 >> 16) == 0xFFFF
        p.major = (v0 >> 8) & 0xFF
        p.minor = v0 & 0xFF
        i = 1
        n = len(tokens)
        while i < n:
            tok = tokens[i]
            low = tok & 0xFFFF
            if low == 0xFFFF:
                break
            if low == 0xFFFE:                       # comment block
                dwords = (tok >> 16) & 0x7FFF
                if dwords and tokens[i + 1] == 0x42415443:   # 'CTAB'
                    p.ctab = _parse_ctab(tokens, i + 1, dwords)
                i += 1 + dwords
                continue
            op = low
            instr = Instr(op)
            instr.control = (tok >> 16) & 0xFF
            instr.predicated = bool((tok >> 28) & 1)
            i += 1
            if op == 31:                            # dcl usage + reg
                usage_tok = tokens[i]
                i += 1
                dst, rel = _parse_param(tokens[i])
                i += 1
                instr.operands.append(dst)
                if dst.rtype == RT_SAMPLER:
                    instr.sampler_type = (usage_tok >> 27) & 0xF
                    p.samplers[dst.num] = instr.sampler_type
                else:
                    instr.usage = usage_tok & 0x1F
                    instr.usage_idx = (usage_tok >> 16) & 0xF
                    if dst.rtype == RT_INPUT:
                        p.inputs[dst.num] = (instr.usage, instr.usage_idx)
                    elif dst.rtype == RT_MISCTYPE:
                        p.misc[dst.num] = instr.usage
            elif op in (81, 48, 47):                # def / defi / defb
                dst, rel = _parse_param(tokens[i])
                i += 1
                instr.operands.append(dst)
                if op == 47:                        # defb: single bool dword
                    instr.imm = [tokens[i], 0, 0, 0]
                    i += 1
                else:
                    instr.imm = list(tokens[i:i + 4])
                    i += 4
                p.defs[(dst.rtype, dst.num)] = instr.imm
            elif op == 37:                          # sincos (version-dependent)
                roles = ["d", "s"] if p.major >= 3 else ["d", "s", "s", "s"]
                for role in roles:
                    o, rel = _parse_param(tokens[i])
                    i += 1
                    if rel:
                        rr, _ = _parse_param(tokens[i])
                        i += 1
                        o.rel = rr
                    instr.operands.append(o)
            else:
                roles = _DST_SRC.get(op, [] if op in _ZERO else None)
                if roles is None:
                    raise NotImplementedError("SM3 opcode %d (%s) unhandled" %
                                              (op, D3DSIO_NAME.get(op, "?")))
                for role in roles:
                    o, rel = _parse_param(tokens[i])
                    i += 1
                    if rel:
                        r, _ = _parse_param(tokens[i])
                        i += 1
                        o.rel = r
                    instr.operands.append(o)
                    if role == "d" and o.rtype == RT_COLOROUT:
                        p.outputs.add(o.num)
            p.instrs.append(instr)
        return p

    @classmethod
    def from_bytes(cls, data):
        toks = list(struct.unpack("<%dI" % (len(data) // 4), data))
        return cls.from_tokens(toks)


def _parse_ctab(tokens, ctab_start, dwords):
    """Parse the CTAB constant-table comment (native shaders only).  Returns
    {name: (register_set, register_index, register_count)}."""
    base = ctab_start + 1                      # skip 'CTAB' fourcc
    blob = b"".join(struct.pack("<I", tokens[base + k] & 0xFFFFFFFF)
                    for k in range(dwords - 1))
    if len(blob) < 28:
        return {}
    size, creator, ver, consts, const_off, flags, target = \
        struct.unpack_from("<7I", blob, 0)
    out = {}
    for k in range(consts):
        # D3DXSHADER_CONSTANTINFO: DWORD Name; WORD RegisterSet, RegisterIndex,
        # RegisterCount, Reserved; DWORD TypeInfo, DefaultValue  (20 bytes)
        name_off, rset, rindex, rcount = \
            struct.unpack_from("<I H H H", blob, const_off + k * 20)
        end = blob.index(b"\0", name_off)
        name = blob[name_off:end].decode("latin1")
        out[name] = (rset, rindex, rcount)
    return out


_CMP = {1: "_gt", 2: "_eq", 3: "_ge", 4: "_lt", 5: "_ne", 6: "_le"}
_SRCMOD_PRE = {1: "-", 5: "-", 8: "-", 12: "-"}   # neg, signneg, x2neg, absneg
_SRCMOD_SUF = {2: "_bias", 3: "_bias", 4: "_bx2", 5: "_bx2", 7: "_x2", 8: "_x2",
               11: "_abs", 12: "_abs", 13: "_not", 6: "_comp"}


def _fmt_swizzle(sw):
    comps = "xyzw"
    s = "".join(comps[(sw >> (2 * k)) & 3] for k in range(4))
    if s[0] == s[1] == s[2] == s[3]:
        return "." + s[0]
    return "" if s == "xyzw" else "." + s


def _fmt_mask(m):
    return "." + "".join(c for c, b in zip("xyzw", range(4)) if m & (1 << b)) \
        if m != 0xF else ""


def _fmt_src(o):
    pre = _SRCMOD_PRE.get(o.srcmod, "")
    body = o.name()
    if 11 <= o.srcmod <= 12:                 # abs wraps the register name
        body += "_abs"
    if o.rel is not None:
        body = "%s[%s%s]" % (REG_PREFIX.get(o.rtype, "?"),
                             o.rel.name(), _fmt_swizzle(o.rel.swizzle))
    suf = _SRCMOD_SUF.get(o.srcmod, "") if not (11 <= o.srcmod <= 12) else ""
    return pre + body + _fmt_swizzle(o.swizzle) + suf


def disasm(p):
    out = ["    %s_%d_%d" % ("ps" if p.is_pixel else "vs", p.major, p.minor)]
    for ins in p.instrs:
        roles = _DST_SRC.get(ins.op, [])
        has_dst = bool(roles) and roles[0] == "d"
        nm = ins.name + _CMP.get(ins.control, "") if ins.op in (40, 41, 44, 45) \
            else ins.name
        if has_dst and ins.operands[0].dstmod & 1:
            nm += "_sat"
        if has_dst and ins.operands[0].dstmod & 2:
            nm += "_pp"
        if ins.imm is not None:
            vals = ",".join("%g" % struct.unpack("<f", struct.pack("<I", x))[0]
                            for x in ins.imm) if ins.op == 81 else \
                ",".join(str(struct.unpack("<i", struct.pack("<I", x))[0])
                         for x in ins.imm)
            out.append("    %s %s, %s" % (nm, ins.operands[0].name(), vals))
            continue
        if ins.op == 31:                     # dcl
            o = ins.operands[0]
            if o.rtype == RT_SAMPLER:
                dim = {2: "_2d", 3: "_volume", 4: "_cube"}.get(ins.sampler_type, "")
                out.append("    dcl%s %s" % (dim, o.name()))
            elif o.rtype == RT_MISCTYPE:
                out.append("    dcl %s" % ("vPos" if ins.usage == 0 else "vFace"))
            else:
                u = USAGE_NAME.get(ins.usage, str(ins.usage))
                ui = str(ins.usage_idx) if ins.usage_idx else ""
                out.append("    dcl_%s%s %s%s" % (u, ui, o.name(), _fmt_mask(o.writemask)))
            continue
        parts = []
        for k, o in enumerate(ins.operands):
            role_dst = k < len(roles) and roles[k] == "d"
            parts.append(o.name() + _fmt_mask(o.writemask) if role_dst else _fmt_src(o))
        out.append("    %s %s" % (nm, ", ".join(parts)))
    return "\n".join(out)


if __name__ == "__main__":
    import sys
    import sc2_d3d_decode as D
    import sc2_cache
    import sc2_ps_layout as L
    cache = D.D3DCache()
    _d, _v, records = sc2_cache.parse_cache(D.D3D_CACHE)
    shown = 0
    for r in records:
        blob = cache.data[r["blob_off"]:r["blob_off"] + r["blobsize"]]
        if blob[0] or (blob[9] & 1) == 0:
            continue
        (_a, _b), vec = sc2_cache.decode_key(r["key"])
        fam = L.family_of(vec)
        if not fam or fam[0] != "Model":
            continue
        toks, desc = cache.decode_blob(r["blob_off"], r["blobsize"])
        prog = SM3Program.from_tokens(toks)
        print("=== Model ps blob_off=%d  instrs=%d  inputs=%s  samplers=%s  "
              "defs=%d  outputs=%s ===" %
              (r["blob_off"], len(prog.instrs),
               {k: USAGE_NAME.get(v[0], v[0]) for k, v in prog.inputs.items()},
               prog.samplers, len(prog.defs), sorted(prog.outputs)))
        print(disasm(prog))
        shown += 1
        if shown >= 2:
            break
