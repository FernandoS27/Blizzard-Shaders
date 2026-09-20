"""DXBC reflection for the Diablo III gates: signatures, resources and cbuffer
layouts read from the container BYTES, plus the ``dcl_`` facts only the
disassembly carries.

Everything a D3 gate compares between a retail program and a slang candidate
comes through here, so both legs are read by the same code. Two slang habits
are normalized on the way in and nowhere else:

* **Semantic indices.** slang's HLSL emit concatenates a field's index onto its
  semantic (``COLOR1`` -> ``COLOR10``), but a system value keeps its own index
  (``SV_ClipDistance1`` stays 1). The recovery is per ROW, ``i // 10 + i % 10``
  on non-``SV_`` entries -- the ``build_bls.fix_dxbc_signatures`` formula. A
  whole-signature "every index is a multiple of ten" test never fires on a D3
  program, because every D3 transport carries ``SV_ClipDistance1``.
* **Reflected names.** slang appends ``_0`` to every symbol and wraps a
  cbuffer's members in a struct of the buffer's name. Cbuffers are compared by
  stripped name and by their flattened scalar layout, never by the wrapper.

    python tools/d3_dxbc.py perm_0b0e4b15.dxbc      # dump one program's surface
"""

from __future__ import annotations

import re
import struct
import subprocess
import sys
from pathlib import Path

DECOMPILER = Path(r'C:\Tools\3Dmigoto\cmd_Decompiler\cmd_Decompiler.exe')

# D3D_SHADER_INPUT_TYPE
SIT = {0: 'cbuffer', 1: 'tbuffer', 2: 'texture', 3: 'sampler', 4: 'uav_rw',
       5: 'structured', 6: 'uav_rw_structured', 7: 'byte', 8: 'uav_rw_byte',
       9: 'uav_append', 10: 'uav_consume', 11: 'uav_rw_counter'}
# D3D_SRV_DIMENSION
DIM = {0: 'unknown', 1: 'buffer', 2: 'texture1d', 3: 'texture1darray', 4: 'texture2d',
       5: 'texture2darray', 6: 'texture2dms', 7: 'texture2dmsarray', 8: 'texture3d',
       9: 'texturecube', 10: 'texturecubearray', 11: 'bufferex'}
SIF_COMPARISON_SAMPLER = 0x2
# D3D_NAME (system values), enough for SM4 VS/PS
SYSVAL = {0: 'NONE', 1: 'POS', 2: 'CLIPDST', 3: 'CULLDST', 4: 'RTINDEX', 5: 'VPINDEX',
          6: 'VERTID', 7: 'PRIMID', 8: 'INSTID', 9: 'FFACE', 10: 'SAMPLE', 64: 'TARGET',
          65: 'DEPTH', 66: 'COVERAGE'}
COMPTYPE = {0: 'unknown', 1: 'uint', 2: 'int', 3: 'float'}
# D3D_SHADER_VARIABLE_CLASS / TYPE
CLS_SCALAR, CLS_VECTOR, CLS_MROWS, CLS_MCOLS, CLS_OBJECT, CLS_STRUCT = 0, 1, 2, 3, 4, 5
VTYPE = {0: 'void', 1: 'bool', 2: 'int', 3: 'float', 19: 'uint', 20: 'uint8', 39: 'double'}

_SLANG_SUFFIX = re.compile(r'_\d+$')


def strip_name(name: str) -> str:
    """Drop slang's ``_0`` reflection suffix (retail names never carry one)."""
    return _SLANG_SUFFIX.sub('', name)


def norm_index(name: str, index: int) -> int:
    """Undo slang's x10 semantic numbering on one signature row."""
    if name.upper().startswith('SV_'):
        return index
    return index // 10 + index % 10


def chunks(blob: bytes) -> dict:
    """``{fourcc: chunk body bytes}``."""
    if blob[:4] != b'DXBC':
        raise ValueError('not a DXBC container')
    count, = struct.unpack_from('<I', blob, 28)
    out = {}
    for i in range(count):
        off, = struct.unpack_from('<I', blob, 32 + i * 4)
        size, = struct.unpack_from('<I', blob, off + 4)
        out[blob[off:off + 4].decode('latin1')] = blob[off + 8:off + 8 + size]
    return out


def _cstr(buf: bytes, off: int) -> str:
    end = buf.index(b'\0', off)
    return buf[off:end].decode('latin1')


def signature(blob: bytes, which: str, *, slang: bool = False) -> list:
    """Rows of ``ISGN``/``OSGN`` as tuples
    ``(NAME, index, register, mask, sysval, comptype)``, in container order.

    ``slang=True`` undoes the x10 index. NAME is upper-cased (fxc keeps the
    source casing of ``SV_Position``; D3D resolves system values by tag).
    """
    body = chunks(blob).get(which)
    if body is None:
        return []
    count, = struct.unpack_from('<I', body, 0)
    rows = []
    for i in range(count):
        name_off, idx, sysval, comp, reg, mask, rw, _a, _b = struct.unpack_from(
            '<IIIIIBBBB', body, 8 + i * 24)
        name = _cstr(body, name_off).upper()
        if slang:
            idx = norm_index(name, idx)
        rows.append((name, idx, reg, _mask(mask), SYSVAL.get(sysval, str(sysval)),
                     COMPTYPE.get(comp, str(comp))))
    return rows


def signature_used(blob: bytes, which: str, *, slang: bool = False) -> dict:
    """``{(NAME, index): used-mask}`` -- the ``rw`` byte (read for inputs,
    never-written for outputs). Informational: fxc 9.29 and d3dcompiler_47 do not
    always agree on it, so no gate compares it."""
    body = chunks(blob).get(which)
    out = {}
    if body is None:
        return out
    count, = struct.unpack_from('<I', body, 0)
    for i in range(count):
        name_off, idx, _s, _c, _r, _m, rw, _a, _b = struct.unpack_from(
            '<IIIIIBBBB', body, 8 + i * 24)
        name = _cstr(body, name_off).upper()
        out[(name, norm_index(name, idx) if slang else idx)] = _mask(rw)
    return out


def _mask(m: int) -> str:
    return ''.join(c for bit, c in zip((1, 2, 4, 8), 'xyzw') if m & bit)


# --------------------------------------------------------------------------
# RDEF
# --------------------------------------------------------------------------

def _type_desc(body, off, sm5):
    cls, typ, rows, cols, elems, nmem, mem_off = struct.unpack_from('<HHHHHHI', body, off)
    return cls, typ, rows, cols, elems, nmem, mem_off


def _scalars(body, type_off, base, sm5, out):
    """Expand one variable's type into ``{byte offset: scalar type}`` leaves, using
    HLSL cbuffer packing (16-byte register rows, arrays stride a full row)."""
    cls, typ, rows, cols, elems, nmem, mem_off = _type_desc(body, type_off, sm5)
    count = max(1, elems)

    def element_size():
        if cls == CLS_STRUCT:
            return None
        if cls in (CLS_SCALAR, CLS_VECTOR):
            return 4 * cols
        if cls == CLS_MROWS:
            return 16 * (rows - 1) + 4 * cols
        if cls == CLS_MCOLS:
            return 16 * (cols - 1) + 4 * rows
        return 0

    stride = None
    for e in range(count):
        at = base if e == 0 else base + e * stride
        if cls == CLS_STRUCT:
            first = len(out)
            last = at
            for m in range(nmem):
                name_off, mtype_off, moff = struct.unpack_from('<III', body, mem_off + m * 12)
                _scalars(body, mtype_off, at + moff, sm5, out)
            last = max(out) + 4 if out else at
            size = last - at
        else:
            vt = VTYPE.get(typ, str(typ))
            if cls in (CLS_SCALAR, CLS_VECTOR):
                for c in range(cols):
                    out[at + 4 * c] = vt
            elif cls == CLS_MROWS:
                for r in range(rows):
                    for c in range(cols):
                        out[at + 16 * r + 4 * c] = vt
            elif cls == CLS_MCOLS:
                for c in range(cols):
                    for r in range(rows):
                        out[at + 16 * c + 4 * r] = vt
            size = element_size()
        if stride is None:
            stride = (size + 15) // 16 * 16 if size else 16


def rdef(blob: bytes) -> dict:
    """``{'resources': [...], 'cbuffers': {stripped name: {...}}}``.

    A resource is ``(kind, register, dimension, count, comparison)`` with kind in
    ``cbuffer/texture/sampler/...`` and register like ``t3``. A cbuffer is
    ``{'size': bytes, 'scalars': {offset: type}}`` flattened through any struct.
    """
    body = chunks(blob).get('RDEF')
    if body is None:
        return {'resources': [], 'cbuffers': {}}
    ncb, cb_off, nres, res_off, minor, major, _pt, _flags, _creator = struct.unpack_from(
        '<IIIIBBHII', body, 0)
    sm5 = body[28:32] == b'RD11'
    var_size = 40 if sm5 else 24
    resources = []
    for i in range(nres):
        name_off, typ, _ret, dim, _ns, bind, cnt, flags = struct.unpack_from(
            '<IIIIIIII', body, res_off + i * 32)
        kind = SIT.get(typ, str(typ))
        prefix = {'cbuffer': 'cb', 'texture': 't', 'sampler': 's'}.get(kind, 'u')
        resources.append({'name': strip_name(_cstr(body, name_off)), 'kind': kind,
                          'register': '%s%d' % (prefix, bind),
                          'dim': DIM.get(dim, str(dim)) if kind == 'texture' else '',
                          'count': cnt,
                          'comparison': bool(flags & SIF_COMPARISON_SAMPLER)
                          if kind == 'sampler' else False})
    cbuffers = {}
    for i in range(ncb):
        name_off, nvar, var_off, size, _fl, _ty = struct.unpack_from('<IIIIII', body, cb_off + i * 24)
        scalars = {}
        names = []
        for v in range(nvar):
            vname, start, vsize, vflags, type_off, _def = struct.unpack_from(
                '<IIIIII', body, var_off + v * var_size)
            names.append(strip_name(_cstr(body, vname)))
            _scalars(body, type_off, start, sm5, scalars)
        cbuffers[strip_name(_cstr(body, name_off))] = {'size': size, 'scalars': scalars,
                                                       'vars': names}
    return {'resources': resources, 'cbuffers': cbuffers}


# --------------------------------------------------------------------------
# disassembly facts
# --------------------------------------------------------------------------

_DCL_CB = re.compile(r'^dcl_constantbuffer\s+CB(\d+)\[(\d+)\],\s*(\w+)')
#: ``dcl_resource_texture2dms(4) (float,...) t0`` keeps its sample count in the kind
_DCL_TEX = re.compile(r'^dcl_resource_(\w+(?:\(\d+\))?)\s*\(([^)]*)\)\s+t(\d+)')
_DCL_SAMP = re.compile(r'^dcl_sampler\s+s(\d+),\s*(\w+)')
_DCL_IN = re.compile(r'^dcl_input(_ps)?(?:_siv|_sgv)?\s+(?:(\w+(?: \w+)?)\s+)?v(\d+)\.?([xyzw]*)(?:,\s*(\w+))?')
_DCL_OUT = re.compile(r'^dcl_output(?:_siv|_sgv)?\s+o(\d+)\.?([xyzw]*)(?:,\s*(\w+))?')


def asm_path(dxbc: Path, *, refresh: bool = True) -> Path:
    """The ``.asm`` beside a ``.dxbc``, re-disassembled when missing or older.

    Retail disassembly never goes stale; a slang build's does
    ([[project_fold_class_counting]]), so every reader goes through here.
    """
    dxbc = Path(dxbc)
    asm = dxbc.with_suffix('.asm')
    if refresh and (not asm.exists() or asm.stat().st_mtime < dxbc.stat().st_mtime):
        subprocess.run([str(DECOMPILER), '-d', str(dxbc)], capture_output=True)
        if not asm.exists():
            raise RuntimeError('disassembly failed for %s' % dxbc)
    return asm


def dcl_facts(asm_text: str) -> dict:
    """Declarations fxc emits into the program body."""
    cbs, texs, samps, ins, outs = {}, {}, {}, [], []
    temps = 0
    for line in asm_text.splitlines():
        s = line.strip()
        if not s.startswith('dcl_'):
            continue
        m = _DCL_CB.match(s)
        if m:
            cbs[int(m.group(1))] = (int(m.group(2)), m.group(3))
            continue
        m = _DCL_TEX.match(s)
        if m:
            texs[int(m.group(3))] = (m.group(1), m.group(2).replace(' ', ''))
            continue
        m = _DCL_SAMP.match(s)
        if m:
            samps[int(m.group(1))] = m.group(2)
            continue
        m = _DCL_IN.match(s)
        if m:
            ins.append((int(m.group(3)), m.group(4), (m.group(2) or '').strip(), m.group(5) or ''))
            continue
        m = _DCL_OUT.match(s)
        if m:
            outs.append((int(m.group(1)), m.group(2), m.group(3) or ''))
            continue
        if s.startswith('dcl_temps'):
            temps = int(s.split()[1])
    return {'cbuffers': cbs, 'textures': texs, 'samplers': samps,
            'inputs': sorted(ins), 'outputs': sorted(outs), 'temps': temps}


def surface(dxbc: Path, *, slang: bool) -> dict:
    """Everything D2 compares, for one program."""
    blob = Path(dxbc).read_bytes()
    text = asm_path(dxbc, refresh=slang).read_text('utf-8', errors='replace')
    return {'isgn': signature(blob, 'ISGN', slang=slang),
            'osgn': signature(blob, 'OSGN', slang=slang),
            'rdef': rdef(blob), 'dcl': dcl_facts(text),
            'model': next((l.strip() for l in text.splitlines()
                           if re.match(r'^(ps|vs)_\d_\d$', l.strip())), '')}


if __name__ == '__main__':
    import json
    for p in sys.argv[1:]:
        s = surface(Path(p), slang='--slang' in sys.argv)
        for cb in s['rdef']['cbuffers'].values():
            cb['scalars'] = '%d leaves, last @%d' % (len(cb['scalars']), max(cb['scalars'] or [0]))
        print(json.dumps(s, indent=1, default=str))
