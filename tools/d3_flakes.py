"""The WhiteoutFlakes engine target of d3_shaders (``D3_TARGET_FLAKES``).

The retail targets reproduce what each retail program DECLARES -- its vertex
streams, interpolant registers and bindings -- so gate D2 can compare it row for
row. The engine cannot feed that: it has one vertex record for every mesh, binds
by its own per-backend scheme, and pairs any vertex slot with any pixel slot. So
the engine target keeps what each program COMPUTES and swaps the declarations:

* **vertex input** -- one fixed stream per kind (``FlakesMeshStream`` /
  ``FlakesParticleStream``, types/streams.slang) whose accessors rebuild each
  retail stream exactly (``MESH_ELEMENTS`` / ``PARTICLE_ELEMENTS`` below);
* **interpolants** -- the retail layout on D3D, which links by semantic and
  register as retail does; on Vulkan, WebGPU and Metal one float4 per retail
  register at ``location = register`` (Metal: ``[[user(D3REG_<register>)]]``),
  which is the same linkage, and no clip distances;
* **bindings** -- CBs at b0-b2, textures and samplers at the retail register, in
  the engine's sets / groups with the pixel stage shifted (``SHIFT``); Metal's
  per-stage argument tables take the registers as they are; a role the slot does
  not bind sits at register 0, where D3D puts it;
* **CBBones** -- the engine's 256-bone palette; the irradiance cube is a cube
  array read at slice 0.

A vertex slot's reads come from its retail-target D3D11 build: the ISGN read
masks of the gate-validated program decide whether the slot declares the bone
stream and which of its reads the engine stream cannot supply exactly.
"""

from __future__ import annotations

import json

import d3_shaders_cfg as C

#: the engine target per backend: slangc target and profiles, BLS api folder,
#: platform tag and outer flags. ``api`` None = from the SPIR-V version word.
TARGETS = {
    'flakes-d3d11': {'target': 'dxbc', 'ext': 'dxbc', 'vs': 'vs_4_0', 'ps': 'ps_4_0', 'extra': [],
                     'backend': 'd3d', 'api': 'dx_5_0', 'tag': b'05XD', 'flags': 0x00000001},
    'flakes-d3d12': {'target': 'dxil', 'ext': 'dxil', 'vs': 'vs_6_0', 'ps': 'ps_6_0', 'extra': [],
                     'backend': 'd3d', 'api': 'dx_6_0', 'tag': b'06XD', 'flags': 0x00010001},
    'flakes-vulkan': {'target': 'spirv', 'ext': 'spv', 'vs': 'glsl_450', 'ps': 'glsl_450',
                      'extra': ['-fvk-use-dx-layout'],
                      'backend': 'vulkan', 'api': None, 'tag': b'RIPS', 'flags': 0},
    'flakes-webgpu': {'target': 'wgsl', 'ext': 'wgsl', 'vs': 'sm_6_0', 'ps': 'sm_6_0', 'extra': [],
                      'backend': 'webgpu', 'api': 'wgsl_1_0', 'tag': b'LSGW', 'flags': 0},
    # .metal source anywhere; macOS links it to the .metallib beside it, which is
    # packed into the v1.8 MTLB container the engine's Metal loader reads (no tag)
    'flakes-metal': {'target': 'metal', 'ext': 'metal', 'vs': 'sm_6_0', 'ps': 'sm_6_0', 'extra': [],
                     'backend': 'metal', 'api': 'metal', 'tag': None, 'flags': None},
}

#: pixel-stage binding offsets (CB, texture, sampler); the vertex stage uses the
#: register itself. Vulkan: set 0 / 1 / 2 with PS at 16 + N. WebGPU: groups 0 / 1
#: / 2 with PS CBs at 4 + b and PS textures / samplers at 12 + N. Metal has none:
#: slang puts bN / tN / sN at [[buffer / texture / sampler(N)]] of each stage.
SHIFT = {'vulkan': (16, 16, 16), 'webgpu': (4, 12, 12)}
#: the highest texture / sampler register each stage can bind without leaving the
#: engine's layout (Vulkan: the pixel stage binds t16-t19 / s16-s19 past its
#: storage buffers, see ``register_binding``; WebGPU's highest binding is 48 and
#: the vertex stage ends where the pixel stage starts, at 12; the Metal device
#: binds texture / sampler indices 0-15 per stage)
MAX_REGISTER = {'vulkan': {'vs': 15, 'ps': 19}, 'webgpu': {'vs': 11, 'ps': 36},
                'metal': {'vs': 15, 'ps': 15}}

#: Vulkan set 1 bindings 32-35 are the pixel stage's storage buffers, so its
#: textures t16-t19 continue at 36 (its samplers s16-s19 simply take 32-35)
VULKAN_PS_HIGH_TEXTURE = 36


def register_binding(be: str, stage: str, kind: str, reg: int) -> int:
    """The binding a texture (``T``) / sampler (``S``) register takes in its
    set / group on a backend with a ``SHIFT``."""
    _cb, tex, samp = SHIFT[be] if stage == 'ps' else (0, 0, 0)
    if be == 'vulkan' and stage == 'ps' and kind == 'T' and reg >= 16:
        return VULKAN_PS_HIGH_TEXTURE + reg - 16
    return (tex if kind == 'T' else samp) + reg


def binding_register(be: str, stage: str, kind: str, binding: int) -> int:
    """The register ``register_binding`` puts at ``binding``."""
    _cb, tex, samp = SHIFT[be] if stage == 'ps' else (0, 0, 0)
    if be == 'vulkan' and stage == 'ps' and kind == 'T' and binding >= VULKAN_PS_HIGH_TEXTURE:
        return 16 + binding - VULKAN_PS_HIGH_TEXTURE
    return binding - (tex if kind == 'T' else samp)

#: the engine's records, element for element: (location, semantic, index, format,
#: byte offset, vertex buffer slot). Semantics are index-free in the source; slang
#: appends a 0.
MESH_ELEMENTS = [
    (0, 'POSITION', 0, 'R32G32B32_FLOAT', 0, 0),
    (1, 'NORMAL', 0, 'R32G32B32_FLOAT', 12, 0),
    (2, 'TEXCOORD', 0, 'R32G32B32A32_FLOAT', 24, 0),
    (3, 'TANGENT', 0, 'R32G32B32A32_FLOAT', 40, 0),
    (4, 'COLOR', 0, 'R16G16B16A16_UNORM', 56, 0),
    (5, 'BINORMAL', 0, 'R8G8B8A8_UINT', 64, 0),
    (6, 'BLENDWEIGHT', 0, 'R8G8B8A8_UNORM', 0, 1),
    (7, 'BLENDINDICES', 0, 'R8G8B8A8_UINT', 4, 1),
]
PARTICLE_ELEMENTS = [
    (0, 'POSITION', 0, 'R32G32B32_FLOAT', 0, 0),
    (1, 'COLOR', 0, 'R8G8B8A8_UNORM', 12, 0),
    (2, 'COLORB', 0, 'R8G8B8A8_UNORM', 16, 0),
    (3, 'TEXCOORD', 0, 'R8G8B8A8_UINT', 20, 0),
    (4, 'TEXCOORDB', 0, 'R8G8B8A8_UINT', 24, 0),
    (5, 'TEXCOORDC', 0, 'R8G8B8A8_UINT', 28, 0),
    (6, 'TEXCOORDD', 0, 'R8G8B8A8_UINT', 32, 0),
    (7, 'TEXCOORDE', 0, 'R8G8B8A8_UINT', 36, 0),
    (8, 'TEXCOORDF', 0, 'R32G32B32A32_FLOAT', 40, 0),
]

#: retail particle vertex declaration (Particle_WriteQuadVertices), by semantic
_PARTICLE_DECL = {('POSITION', 0, 'float'), ('COLOR', 0, 'float'), ('COLOR', 1, 'float'),
                  ('TEXCOORD', 0, 'uint'), ('TEXCOORD', 1, 'uint'), ('TEXCOORD', 2, 'uint'),
                  ('TEXCOORD', 3, 'uint'), ('TEXCOORD', 4, 'uint'), ('TEXCOORD', 5, 'float')}

#: what the mesh stream gives a retail stream it has no exact source for, by
#: (semantic, index, component type); every read of one is listed per slot
_MESH_SUBSTITUTE = {
    ('TEXCOORD', 0, 'float'): 'the engine uv0 floats',
    ('TEXCOORD', 1, 'float'): 'the engine uv1 floats',
    ('TEXCOORD', 2, 'float'): 'the position',
    ('TEXCOORD', 2, 'uint'): 'zero',
    ('TEXCOORD', 3, 'float'): 'zero',
    ('TEXCOORD', 3, 'uint'): 'zero',
    ('TEXCOORD', 4, 'float'): 'zero',
    ('TEXCOORD', 4, 'uint'): 'zero',
    ('TEXCOORD', 5, 'float'): 'zero',
    ('TEXCOORD', 5, 'uint'): 'zero',
}

#: retail texture dimension -> the manifest's kind
TEXTURE_KIND = {'texture2d': '2d', 'texturecube': 'cube', 'texture2darray': '2darray',
                'texture2dms': '2dms', 'texture3d': '3d', 'texturecubearray': 'cubearray'}


def is_flakes(target: str) -> bool:
    return target in TARGETS


def backend(target: str) -> str:
    return TARGETS[target]['backend']


def stream_kind(measured: dict) -> str:
    """``particle`` for retail's particle vertex, ``mesh`` for any other stream
    set, ``none`` for a program without vertex input."""
    rows = measured.get('streams') or []
    if not rows:
        return 'none'
    sems = {(n, i, comp) for n, i, _r, _m, _s, comp in rows}
    return 'particle' if sems == _PARTICLE_DECL else 'mesh'


def reads_bones(reads: dict) -> bool:
    return any(reads.get((n, 0)) for n in ('BLENDINDICES', 'BLENDWEIGHT'))


def unsuppliable(measured: dict, reads: dict) -> list:
    """The slot's retail stream reads the engine stream gives a stand-in for, as
    ``"<SEM><idx>.<lanes> (<type>): <stand-in>"``."""
    if stream_kind(measured) != 'mesh':
        return []
    out = []
    for name, idx, _r, mask, _s, comp in measured.get('streams') or []:
        used = reads.get((name, idx), '')
        if not used:
            continue
        ty = C._vec(comp, len(mask))
        sub = _MESH_SUBSTITUTE.get((name, idx, comp))
        if sub:
            if name == 'TEXCOORD' and idx < 2 and comp == 'float' and set(used) & set('zw'):
                sub += ' (z = 0, w = 1)'
            out.append('%s%d.%s (%s): %s' % (name, idx, used, ty, sub))
        elif name == 'TANGENT' and 'w' in used:
            out.append('TANGENT%d.w (%s): zero' % (idx, ty))
    return out


def register_transport(rows: list) -> list:
    """``D3_IO_*`` defines for Vulkan / WebGPU / Metal: one float4 per retail
    register at ``location = register``, each semantic a swizzle of its register;
    no clip distances (the engine enables none)."""
    d, at = [], {}
    n = 0
    for name, idx, reg, mask, _sysval, _comp in rows:
        if name == 'SV_CLIPDISTANCE':
            continue
        if name == 'SV_POSITION':
            d += ['D3_IO_%d=1' % n, 'D3_IO_%d_TYPE=float4' % n, 'D3_IO_%d_SEM=SV_Position%d' % (n, idx),
                  'D3_IO_AT_SV_POSITION%d=io%d' % (idx, n)]
            n += 1
            continue
        if reg not in at:
            at[reg] = n
            d += ['D3_IO_%d=1' % n, 'D3_IO_%d_TYPE=float4' % n, 'D3_IO_%d_SEM=D3REG%d' % (n, reg),
                  'D3_IO_%d_LOC=%d' % (n, reg)]
            n += 1
        d.append('D3_IO_AT_%s%d=io%d.%s' % (name, idx, at[reg], mask))
    return d


#: per-program engine-target exclusions (d3_perms/_flakes_exceptions.json)
_EXCEPTIONS = []


def exceptions() -> dict:
    if not _EXCEPTIONS:
        path = C.REPO / 'd3_perms' / '_flakes_exceptions.json'
        data = json.loads(path.read_text('utf-8')) if path.exists() else {}
        _EXCEPTIONS.append({k: v for k, v in data.items() if not k.startswith('_')})
    return _EXCEPTIONS[0]


def unsupported(measured: dict, target: str, stage: str, program: str | None = None) -> str | None:
    """Why the slot cannot run on the target's backend, None when it can."""
    why = exceptions().get(program, {}).get(target) if program else None
    if why:
        return why
    be = backend(target)
    for reg, kind, dim, _cmp, _name in measured['resources']:
        if kind == 'texture' and dim not in ('texture2d', 'texturecube'):
            return '%s is a %s, which no engine-target role declares' % (reg, dim)
    if be == 'd3d':
        return None
    top = MAX_REGISTER[be][stage]
    for reg, kind, _dim, _cmp, _name in measured['resources']:
        if kind in ('texture', 'sampler') and int(reg[1:]) > top:
            return '%s is past the %s %s layout (registers 0-%d)' % (reg, be, stage, top)
    return None


def engine_spec(spec: C.Spec, measured: dict, target: str, stage: str, reads: dict) -> C.Spec:
    """The spec a slot compiles to under the engine target."""
    be = backend(target)
    d = [x for x in spec.defines if not x.startswith('D3_IN_')]
    if be != 'd3d':
        d = [x for x in d if not x.startswith('D3_IO_')] + register_transport(measured['transport'])
    d.append('D3_TARGET_FLAKES=1')
    if stage == 'vs':
        for name, idx, _r, mask, _s, comp in measured.get('streams') or []:
            d.append('D3_FL_%s%d=%s' % (name, idx, C._vec(comp, len(mask))))
        if stream_kind(measured) == 'particle':
            d.append('D3_FL_PARTICLE=1')
        elif reads_bones(reads):
            d.append('D3_FL_SKINNED=1')
    if be in SHIFT:
        cb, tex, samp = SHIFT[be] if stage == 'ps' else (0, 0, 0)
        # an unbound role defaults to register 0, as on D3D (types/textures.slang)
        d += ['D3_VK_CB_BASE=%d' % cb, 'D3_VK_T_BASE=%d' % tex, 'D3_VK_S_BASE=%d' % samp]
        for x in spec.defines:
            if x.startswith(('D3_T_', 'D3_S_')):
                name, reg = x.split('=')
                kind, role = name[3], name[5:]
                d.append('D3_VK_%s_%s=%d' % (kind, role, register_binding(be, stage, kind, int(reg[1:]))))
    return C.Spec(spec.entry, spec.specialize, tuple(d))


def profile(target: str, stage: str, measured: dict) -> str:
    """D3D11 stays at retail's shader model 4, but a cube array needs 4.1."""
    p = TARGETS[target][stage]
    if target == 'flakes-d3d11' and any(dim == 'texturecube' for _r, _k, dim, _c, _n in measured['resources']):
        p = p.replace('_4_0', '_4_1')
    return p


def slot_record(bid: str, slot: dict, reads: dict | None) -> dict:
    """The engine manifest's description of one slot (backends filled by the caller)."""
    stage = bid.split('_', 1)[0]
    rec = {'bundle': bid, 'stage': stage, 'slot': slot['slot'],
           'hashes': sorted({r['hash'].lower() for r in slot['retail']})}
    m = slot['measured']
    if stage == 'vs':
        kind = stream_kind(m)
        rec['stream'] = kind
        rec['readsBones'] = bool(reads and kind == 'mesh' and reads_bones(reads))
        rec['unsuppliable'] = unsuppliable(m, reads or {})
    else:
        tex = sorted((int(r[1:]), TEXTURE_KIND.get(dim, dim)) for r, k, dim, _c, _n in m['resources']
                     if k == 'texture')
        samp = sorted((int(r[1:]), bool(cmp)) for r, k, _d, cmp, _n in m['resources'] if k == 'sampler')
        rec['textures'] = [[reg, kind] for reg, kind in tex]
        rec['samplers'] = [[reg, 'comparison' if cmp else 'sampler'] for reg, cmp in samp]
        rec['maxTexture'] = max((reg for reg, _k in tex), default=-1)
        rec['maxSampler'] = max((reg for reg, _c in samp), default=-1)
    return rec
