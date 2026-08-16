"""Executor for parsed D3D9 SM3 programs (sm3_parse.SM3Program).

Used to compare a *retail* decompressed shader against our *native* `ps_3_0`
compile of the same permutation: run BOTH through this one interpreter on
identical random inputs/constants/textures and diff the color outputs.  Because
both shaders go through the same interpreter, float64 consistency is enough — no
GPU-exact float32 is required (identical shaders -> identical results).

Register files: r# temps, v# inputs, c#/i#/b# constants, s# samplers, oC# color
outputs, oDepth, a0 address, aL loop counter, p0 predicate.  Control flow:
if/ifc/else/endif, rep/endrep, loop/endloop, break/breakc.
"""
import math
import struct

import sm3_parse as P

try:
    import dxbc_interp as di
    _TEX = di.TextureModel
except Exception:                       # pragma: no cover
    _TEX = None


class _Break(Exception):
    pass


def _f2i(x):
    return struct.unpack("<i", struct.pack("<f", x))[0] if False else int(x)


def _build_blocks(instrs, i=0):
    """Turn the flat instr list into a nested block tree."""
    body = []
    n = len(instrs)
    while i < n:
        ins = instrs[i]
        op = ins.op
        if op in (40, 41):                       # if / ifc
            then_b, i = _build_blocks(instrs, i + 1)
            else_b = []
            if i < n and instrs[i].op == 42:     # else
                else_b, i = _build_blocks(instrs, i + 1)
            i += 1                               # skip endif
            body.append(("if", ins, then_b, else_b))
        elif op in (27, 38):                     # loop / rep
            inner, i = _build_blocks(instrs, i + 1)
            i += 1                               # skip endloop/endrep
            body.append(("loop", ins, inner))
        elif op in (42, 43, 29, 39):             # else/endif/endloop/endrep
            return body, i
        elif op == 44:                           # break
            body.append(("break", ins))
            i += 1
        else:
            body.append(("op", ins))
            i += 1
    return body, i


class SM3VM:
    def __init__(self, prog, textures=None):
        self.prog = prog
        self.r = [[0.0, 0.0, 0.0, 0.0] for _ in range(32)]
        self.v = {}
        self.c = {}
        self.i = {}
        self.b = {}
        self.a0 = [0.0, 0.0, 0.0, 0.0]
        self.aL = 0.0
        self.p0 = [0.0, 0.0, 0.0, 0.0]
        self.oC = {}
        self.oDepth = [0.0, 0.0, 0.0, 0.0]
        self.o = {}                              # vs outputs o#
        self.discarded = False
        self.tex = textures
        # bake def/defi/defb immediates
        for (rtype, num), imm in prog.defs.items():
            if rtype == P.RT_CONST:
                self.c[num] = [struct.unpack("<f", struct.pack("<I", x))[0] for x in imm]
            elif rtype == P.RT_CONSTINT:
                self.i[num] = [struct.unpack("<i", struct.pack("<I", x))[0] for x in imm]
            elif rtype == P.RT_CONSTBOOL:
                self.b[num] = [imm[0] & 1] * 4

    # ---- register access -------------------------------------------------
    def _reg(self, rtype, num):
        if rtype == P.RT_TEMP:
            return self.r[num]
        if rtype == P.RT_INPUT:
            return self.v.get(num, [0.0, 0.0, 0.0, 0.0])
        if rtype == P.RT_CONST:
            return self.c.get(num, [0.0, 0.0, 0.0, 0.0])
        if rtype == P.RT_CONSTINT:
            return self.i.get(num, [0, 0, 0, 0])
        if rtype == P.RT_CONSTBOOL:
            return self.b.get(num, [0, 0, 0, 0])
        if rtype == P.RT_LOOP:
            return [self.aL] * 4
        if rtype == P.RT_ADDR:
            return self.a0
        if rtype == P.RT_MISCTYPE:
            return self.v.get("misc%d" % num, [0.0, 0.0, 0.0, 0.0])
        if rtype == P.RT_PREDICATE:
            return self.p0
        if rtype in (P.RT_COLOROUT,):
            return self.oC.setdefault(num, [0.0, 0.0, 0.0, 0.0])
        if rtype == P.RT_DEPTHOUT:
            return self.oDepth
        if rtype == P.RT_OUTPUT:
            return self.o.setdefault(num, [0.0, 0.0, 0.0, 0.0])
        return [0.0, 0.0, 0.0, 0.0]

    def _rel_index(self, o):
        base = o.num
        if o.rel is not None:
            comp = o.rel.swizzle & 3
            rv = self._reg(o.rel.rtype, o.rel.num)[comp]
            base += int(round(rv))
        return base

    def read_src(self, o):
        vals = self._reg(o.rtype, self._rel_index(o))
        sw = o.swizzle
        v = [float(vals[(sw >> (2 * k)) & 3]) for k in range(4)]
        m = o.srcmod
        if m == 0:
            return v
        if m == 1:
            return [-x for x in v]
        if m == 11:
            return [abs(x) for x in v]
        if m == 12:
            return [-abs(x) for x in v]
        if m == 2:
            return [x - 0.5 for x in v]
        if m == 3:
            return [-(x - 0.5) for x in v]
        if m == 4:
            return [2.0 * x - 1.0 for x in v]
        if m == 5:
            return [-(2.0 * x - 1.0) for x in v]
        if m == 6:
            return [1.0 - x for x in v]
        if m == 7:
            return [2.0 * x for x in v]
        if m == 8:
            return [-2.0 * x for x in v]
        return v

    def write_dst(self, o, v):
        if o.dstmod & 1:                          # _sat
            v = [min(1.0, max(0.0, x)) for x in v]
        idx = o.num
        reg = self._reg(o.rtype, idx)
        for k in range(4):
            if o.writemask & (1 << k):
                reg[k] = v[k]
        if o.rtype == P.RT_ADDR or o.rtype == P.RT_PREDICATE:
            pass

    # ---- execution -------------------------------------------------------
    def run(self, max_loop=1 << 16):
        blocks, _ = _build_blocks(self.prog.instrs)
        self._budget = [max_loop]
        try:
            self._exec(blocks)
        except _Break:
            pass
        return self

    def _exec(self, blocks):
        for kind, *rest in blocks:
            if kind == "op":
                self._do(rest[0])
            elif kind == "break":
                raise _Break()
            elif kind == "if":
                ins, then_b, else_b = rest
                if self._cond(ins):
                    self._exec(then_b)
                else:
                    self._exec(else_b)
            elif kind == "loop":
                self._loop(rest[0], rest[1])

    def _loop(self, hdr, inner):
        if hdr.op == 38:                          # rep i#
            cnt = int(self._reg(hdr.operands[0].rtype, hdr.operands[0].num)[0])
            for _ in range(max(0, cnt)):
                self._budget[0] -= 1
                if self._budget[0] < 0:
                    return
                try:
                    self._exec(inner)
                except _Break:
                    break
        else:                                     # loop aL, i#
            ir = self._reg(hdr.operands[1].rtype, hdr.operands[1].num)
            cnt, init, step = int(ir[0]), ir[1], ir[2]
            saved = self.aL
            self.aL = init
            for _ in range(max(0, cnt)):
                self._budget[0] -= 1
                if self._budget[0] < 0:
                    break
                try:
                    self._exec(inner)
                except _Break:
                    break
                self.aL += step
            self.aL = saved

    def _cond(self, ins):
        if ins.op == 40:                          # if bool
            b = self.read_src(ins.operands[0])[0]
            return bool(b)
        a = self.read_src(ins.operands[0])[0]     # ifc
        c = self.read_src(ins.operands[1])[0]
        return _compare(ins.control, a, c)

    def _do(self, ins):
        op = ins.name
        o = ins.operands
        if op == "texkill":
            v = self.read_src(o[0])
            if any(x < 0.0 for x in v[:4]):
                self.discarded = True
            return
        if op == "breakc":                            # conditional break (ray-march exit)
            a = self.read_src(o[0])[0]
            b = self.read_src(o[1])[0]
            if _compare(ins.control, a, b):
                raise _Break()
            return
        if op == "break":                             # unconditional (if parsed as op)
            raise _Break()
        if op in ("dcl", "def", "defi", "defb", "nop", "ret"):
            return

        def s(k):
            return self.read_src(o[k])

        if op == "mov":
            r = s(1)
        elif op == "add":
            a, b = s(1), s(2); r = [a[k] + b[k] for k in range(4)]
        elif op == "sub":
            a, b = s(1), s(2); r = [a[k] - b[k] for k in range(4)]
        elif op == "mul":
            a, b = s(1), s(2); r = [a[k] * b[k] for k in range(4)]
        elif op == "mad":
            a, b, c = s(1), s(2), s(3); r = [a[k] * b[k] + c[k] for k in range(4)]
        elif op == "lrp":
            t, a, b = s(1), s(2), s(3)
            r = [b[k] + t[k] * (a[k] - b[k]) for k in range(4)]
        elif op == "dp3":
            a, b = s(1), s(2); d = sum(a[k] * b[k] for k in range(3)); r = [d] * 4
        elif op == "dp4":
            a, b = s(1), s(2); d = sum(a[k] * b[k] for k in range(4)); r = [d] * 4
        elif op == "dp2add":
            a, b, c = s(1), s(2), s(3)
            d = a[0] * b[0] + a[1] * b[1] + c[0]; r = [d] * 4
        elif op == "min":
            a, b = s(1), s(2); r = [min(a[k], b[k]) for k in range(4)]
        elif op == "max":
            a, b = s(1), s(2); r = [max(a[k], b[k]) for k in range(4)]
        elif op == "slt":
            a, b = s(1), s(2); r = [1.0 if a[k] < b[k] else 0.0 for k in range(4)]
        elif op == "sge":
            a, b = s(1), s(2); r = [1.0 if a[k] >= b[k] else 0.0 for k in range(4)]
        elif op == "cmp":
            a, b, c = s(1), s(2), s(3)
            r = [b[k] if a[k] >= 0.0 else c[k] for k in range(4)]
        elif op == "rcp":
            x = s(1)[0]; r = [(1.0 / x) if x != 0.0 else _big(x)] * 4
        elif op == "rsq":
            x = abs(s(1)[0]); r = [(1.0 / math.sqrt(x)) if x != 0.0 else 1e30] * 4
        elif op == "exp":
            r = [2.0 ** s(1)[0]] * 4
        elif op == "log":
            x = abs(s(1)[0]); r = [math.log(x, 2.0) if x != 0.0 else -1e30] * 4
        elif op == "pow":
            a = abs(s(1)[0]); b = s(2)[0]
            r = [(a ** b) if a != 0.0 else (0.0 if b > 0 else 1e30)] * 4
        elif op == "frc":
            a = s(1); r = [a[k] - math.floor(a[k]) for k in range(4)]
        elif op == "abs":
            a = s(1); r = [abs(a[k]) for k in range(4)]
        elif op == "nrm":
            a = s(1); ln = math.sqrt(sum(a[k] * a[k] for k in range(3)))
            inv = (1.0 / ln) if ln != 0.0 else 0.0
            r = [a[k] * inv for k in range(4)]
        elif op == "mova":
            a = s(1); r = [float(int(round(a[k]))) for k in range(4)]
        elif op == "sincos":
            x = s(1)[0]; r = [math.cos(x), math.sin(x), 0.0, 0.0]
        elif op == "crs":
            a, b = s(1), s(2)
            r = [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2],
                 a[0] * b[1] - a[1] * b[0], 0.0]
        elif op == "dst":
            a, b = s(1), s(2)
            r = [1.0, a[1] * b[1], a[2], b[3]]
        elif op in ("dsx", "dsy"):
            r = [0.0, 0.0, 0.0, 0.0]              # screen derivatives -> 0
        elif op in ("texld", "texldl", "texldd", "texldp"):
            r = self._sample(ins)
        elif op in ("texdp3", "texdp3tex", "texdepth"):
            r = [0.0, 0.0, 0.0, 0.0]
        else:
            raise NotImplementedError("SM3 exec opcode %s" % op)
        self.write_dst(o[0], r)

    def _sample(self, ins):
        o = ins.operands
        coord = self.read_src(o[1])
        samp = o[2].num
        if self.tex is None:
            return [0.0, 0.0, 0.0, 0.0]
        texel = self.tex.sample(samp, coord)
        return list(texel)


def _compare(ctrl, a, c):
    if ctrl == 1:
        return a > c
    if ctrl == 2:
        return a == c
    if ctrl == 3:
        return a >= c
    if ctrl == 4:
        return a < c
    if ctrl == 5:
        return a != c
    if ctrl == 6:
        return a <= c
    return a > c


def _big(x):
    return math.inf if x >= 0 else -math.inf


def execute(prog, inputs=None, consts=None, textures=None, misc=None,
            max_loop=1 << 16):
    """Run `prog`; `inputs`={vnum:[4]}, `consts`={cnum:[4]}, `misc`={num:[4]}
    (vPos=0, vFace=1).  Returns the SM3VM (read .oC / .oDepth / .discarded)."""
    vm = SM3VM(prog, textures=textures)
    if inputs:
        vm.v.update(inputs)
    if misc:
        for k, val in misc.items():
            vm.v["misc%d" % k] = val
    if consts:
        for k, val in consts.items():
            vm.c[k] = list(val)                   # external overrides (not def'd)
    # re-bake defs so external consts never clobber baked immediates
    for (rtype, num), imm in prog.defs.items():
        if rtype == P.RT_CONST:
            vm.c[num] = [struct.unpack("<f", struct.pack("<I", x))[0] for x in imm]
    vm.run(max_loop=max_loop)
    return vm
