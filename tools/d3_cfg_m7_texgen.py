"""Roots and mutations of workspace m7_texgen (plan M7, residue of vs_legacy).

The 106 residue programs of this workspace are placed as data in
d3_residue.json (texgen_vs_main, actor_vs_main, surface_vs_main,
particle_vs_main and the new restore_vs_main); there are no translators. New
policies live in their own files:

    roots/legacy/texgen_residue.slang     poses, colours, generators of texgen_vs_main
    roots/legacy/restore_vs.slang         restore_vs_main (the depth restore quad)
    roots/actor/actor_residue_vs.slang    IrradianceLayeredVertex (actor_vs_main)
    roots/surface/surface_residue_vs.slang ShadingNone, VertexLitSwayProbe (surface_vs_main)
"""

import d3_shaders_cfg as C

_RESTORE = 'roots/legacy/restore_vs.slang'
_TEXGEN = 'roots/legacy/texgen_residue.slang'
_ACTOR = 'roots/actor/actor_residue_vs.slang'
_SURFACE = 'roots/surface/surface_residue_vs.slang'


def _src(name, root, file, old, new, cls=''):
    return dict(name=name, root=root, kind='src', file=file, old=old, new=new, cls=cls)


#: gate D8 mutations for this workspace's roots, as dicts of d3_mutate.Mutation fields
MUTATIONS = [
    # --- restore_vs (new root) -------------------------------------------------
    dict(name='restore-transport-width', root='restore_vs_main', kind='cfg', spec=C.widen_first_row(),
         cls='transport'),
    _src('restore-y-flip', 'restore_vs_main', _RESTORE, 'float2(2.0, -2.0)', 'float2(2.0, 2.0)'),
    _src('restore-corner-bias', 'restore_vs_main', _RESTORE, '(corner - 0.5)', '(corner - 0.25)'),
    _src('restore-texel-centre', 'restore_vs_main', _RESTORE, 'corner * targetDimensions.xy + 0.5',
         'corner * targetDimensions.xy - 0.5'),
    _src('restore-target-axes', 'restore_vs_main', _RESTORE, 'corner * targetDimensions.xy',
         'corner * targetDimensions.yx'),
    _src('restore-uv-range', 'restore_vs_main', _RESTORE, 'float2 corner = d3DecodeUv0(',
         'float2 corner = d3DecodeUv1('),

    # --- texgen_vs policies added here -------------------------------------------
    _src('texgen-residue-vc-modulate', 'texgen_vs_main', _TEXGEN,
         'return T.rgb(i, v) * i.color0().rgb; }', 'return T.rgb(i, v) * i.color0().bgr; }'),
    _src('texgen-residue-raw-normal', 'texgen_vs_main', _TEXGEN,
         'return P.pose(i, float3(i.normalBits().xyz));', 'return P.pose(i, normal);'),
    _src('texgen-residue-absent-uv-range', 'texgen_vs_main', _TEXGEN,
         '    if (scale != 0)\n        return d3DecodeUv1(bits);',
         '    if (scale == 0)\n        return d3DecodeUv1(bits);'),
    _src('texgen-residue-field-line', 'texgen_vs_main', _TEXGEN,
         'uv.y + float(SIGN) * targetDimensions.w', 'uv.y + float(SIGN) * targetDimensions.z'),
    _src('texgen-residue-fresnel-power', 'texgen_vs_main', _TEXGEN,
         '(square * square) * grazing * 0.5 + 0.5', '(square * grazing) * grazing * 0.5 + 0.5'),
    _src('texgen-residue-secondary-white', 'texgen_vs_main', _TEXGEN,
         'o.setColor1(float4(1.0, 1.0, 1.0, 1.0));', 'o.setColor1(float4(1.0, 1.0, 1.0, 0.0));'),

    # --- actor_vs / surface_vs models added here ----------------------------------
    _src('actor-layered-detail-uv', 'actor_vs_main', _ACTOR,
         'd3TexTransform(matTex3[0], matTex3[1], uv1)', 'd3TexTransform(matTex3[0], matTex3[1], uv0)'),
    _src('actor-layered-ambient-dropped', 'actor_vs_main', _ACTOR,
         'float4(light.diffuse * MeshLighting.x', 'float4((light.diffuse + light.ambient) * MeshLighting.x'),
    _src('surface-sway-probe-stream', 'surface_vs_main', _SURFACE,
         'o.setColor0(float4(i.color1().xyz,', 'o.setColor0(float4(i.color0().xyz,'),
    _src('surface-shading-none-alpha', 'surface_vs_main', _SURFACE,
         'inout D3Interpolants o) {}', 'inout D3Interpolants o) { o.setColor0(float4(0.0, 0.0, 0.0, 1.0)); }'),
]

#: roots that must include a tie-flip / bone-order mutation
ALPHA_ROOTS = []
SKINNED_ROOTS = []

#: roots added in this workspace, with the bundle each belongs to
NEW_ROOTS = {'restore_vs_main': 'vs_legacy'}
