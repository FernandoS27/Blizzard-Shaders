"""Translators for the surface vertex root (surface_vs_main), ported in workspace surface_vs.

Registered with the same decorator as tools/d3_shaders_cfg.py; the helpers
(on, boolean, alpha_test, swap_specialize, widen_first_row, shift_first_texture)
come from there too.

A surface slot is ``surface_vs_main<placement, surface model>``. Deferred
(per-pixel) passes write their tangent frame into five consecutive texture
coordinates ending at the highest TEXCOORD the program declares; where that
frame starts is material data the local defines do not carry, so it is read
from the measured interpolant layout.
"""

import d3_shaders_cfg as C
from d3_shaders_cfg import translator, on, boolean

ROOT = 'surface_vs_main'


def frame_first(measured) -> int:
    """First TEXCOORD index of the deferred tangent frame (view position)."""
    return max(idx for name, idx, *_ in measured['transport'] if name == 'TEXCOORD') - 4


def _b(defines, name) -> str:
    return boolean(on(defines, name))


def _mesh(shading: str, texgen: str) -> str:
    return 'MeshSurface<%s, %s>' % (shading, texgen)


# --------------------------------------------------------------------------
# Prop.fx
# --------------------------------------------------------------------------

@translator('Prop.fx__vs_prop')
def _prop(defines, measured):
    if on(defines, 'SKINNED'):
        place = 'SkinnedMesh'
    elif on(defines, 'DEFORM'):
        place = 'WindSway<%s>' % _b(defines, 'WEATHER')
    else:
        place = 'RigidMesh'
    if on(defines, 'LIT'):
        shading = 'VertexLit<%s, %s, false, MaterialAlpha>' % (_b(defines, 'SPOTLIGHT'), _b(defines, 'GLOSS'))
    else:
        shading = 'VertexUnlit<MaterialAlpha>'
    texgen = 'ScreenReflection' if on(defines, 'GLOSS') else 'PlanarProjection'
    return ROOT, [place, _mesh(shading, texgen)]


@translator('Prop.fx__vs_prop_vertalpha')
def _prop_vertalpha(defines, measured):
    place = 'WindSway<false>' if on(defines, 'DEFORM') else 'SkinnedMesh'
    shading = 'VertexLit<false, %s, false, VertexMaterialAlpha>' % _b(defines, 'GLOSS')
    texgen = 'ScreenReflection' if on(defines, 'GLOSS') else 'PlanarProjection'
    return ROOT, [place, _mesh(shading, texgen)]


@translator('Prop.fx__vs_prop_prepass')
def _prop_prepass(defines, measured):
    return ROOT, ['SkinnedMesh', 'DepthPrepass']


# --------------------------------------------------------------------------
# Scene.fx
# --------------------------------------------------------------------------

def _scene_texgen(defines) -> str:
    return 'ShiftedScreenReflection' if on(defines, 'GLOSS') else 'PlanarProjection'


@translator('Scene.fx__vs_scene')
def _scene(defines, measured):
    if on(defines, 'PER_PIXEL'):
        shading = 'TangentFrame<%d, MaterialAlpha>' % frame_first(measured)
    elif on(defines, 'LIT'):
        shading = 'VertexLit<%s, %s, %s, MaterialAlpha>' % (_b(defines, 'SPOTLIGHT'), _b(defines, 'GLOSS'),
                                                            _b(defines, 'TWO_SIDED'))
    else:
        shading = 'VertexUnlit<MaterialAlpha>'
    return ROOT, ['RigidMesh', _mesh(shading, _scene_texgen(defines))]


@translator('Scene.fx__vs_scene_vertalpha')
def _scene_vertalpha(defines, measured):
    if on(defines, 'PREPASS'):
        shading = 'TangentFrame<%d, VertexMaterialAlpha>' % frame_first(measured)
    else:
        alpha = 'NearFadeAlpha' if on(defines, 'NEARFADE') else 'VertexMaterialAlpha'
        shading = 'VertexLit<false, %s, false, %s>' % (_b(defines, 'GLOSS'), alpha)
    return ROOT, ['RigidMesh', _mesh(shading, _scene_texgen(defines))]


@translator('Scene.fx__vs_scene_aux')
def _scene_aux(defines, measured):
    return ROOT, ['CurveSway', _mesh('VertexLit<false, false, false, MaterialAlpha>', 'PlanarProjection')]


def _scene_floor(defines, measured, per_pixel: str, gloss: bool, texgen: str):
    if on(defines, per_pixel):
        shading = 'TangentFrame<%d, MaterialAlpha>' % frame_first(measured)
    else:
        shading = 'VertexLit<false, %s, false, MaterialAlpha>' % boolean(gloss)
    return ROOT, ['RigidMesh', _mesh(shading, texgen)]


@translator('Scene.fx__vs_scene_glow_2tex')
def _scene_glow(defines, measured):
    return _scene_floor(defines, measured, 'PER_PIXEL', False, 'TwoTextureGlow')


@translator('Scene.fx__vs_scene_act4_floor')
def _scene_act4(defines, measured):
    return _scene_floor(defines, measured, 'PER_PIXEL', True, 'PlayerFadeFloor')


@translator('Scene.fx__vs_scene_overlay')
def _scene_overlay(defines, measured):
    return _scene_floor(defines, measured, 'PERPIXEL', True, 'OverlayProjection')


# --------------------------------------------------------------------------
# Landscape.fx
# --------------------------------------------------------------------------

def _terrain(defines, measured, layers: str, deferred: str, gloss: bool, spot: bool):
    if on(defines, deferred):
        model = 'TerrainPrepass<%s, %s, %d>' % (layers, boolean(gloss), frame_first(measured))
    else:
        model = 'Terrain<%s, %s, %s>' % (layers, boolean(spot), boolean(gloss))
    return ROOT, ['RigidMesh', model]


@translator('Landscape.fx__vs_landscape5', 'Landscape.fx__vs_landscape_webskin')
def _landscape5(defines, measured):
    return _terrain(defines, measured, 'FiveLayerGround', 'PREPASS', on(defines, 'GLOSS'), on(defines, 'SPOTLIGHT'))


@translator('Landscape.fx__vs_landscape5_water')
def _landscape5_water(defines, measured):
    return _terrain(defines, measured, 'FiveLayerWater', 'PREPASS', on(defines, 'GLOSS'), False)


@translator('Landscape.fx__vs_landscape2')
def _landscape2(defines, measured):
    return _terrain(defines, measured, 'TwoLayerFloor', 'PER_PIXEL_LIGHTING', False, False)


def _side(defines, measured, deferred: str, gloss: bool):
    if on(defines, deferred):
        model = 'SideProjectedTerrainPrepass<%s, %d>' % (boolean(gloss), frame_first(measured))
    else:
        model = 'SideProjectedTerrain<%s>' % boolean(gloss)
    return ROOT, ['RigidMesh', model]


@translator('Landscape.fx__vs_landscape5_sideproj')
def _sideproj(defines, measured):
    return _side(defines, measured, 'PREPASS', False)


@translator('Landscape.fx__vs_landscape5_sideproj_gloss_c')
def _sideproj_gloss(defines, measured):
    return _side(defines, measured, 'PER_PIXEL_LIGHTING', True)


# --------------------------------------------------------------------------
# Reflection.fx, InteractiveFog.fx
# --------------------------------------------------------------------------

@translator('Reflection.fx__main_vs_largewater')
def _largewater(defines, measured):
    place = 'SkinnedMesh' if on(defines, 'SKINNING') else 'RigidMeshPoint'
    return ROOT, [place, 'ReflectiveWater<%s, false>' % _b(defines, 'LIGHTING')]


@translator('Reflection.fx__main_vs_river')
def _river(defines, measured):
    return ROOT, ['RigidMeshPoint', 'ReflectiveWater<true, true>']


@translator('InteractiveFog.fx__vs_fog')
def _fog(defines, measured):
    return ROOT, ['RigidMesh', 'FogPlane<%s, MaterialAlpha>' % _b(defines, 'VERTEX_LIGHTING')]


@translator('InteractiveFog.fx__vs_fog_vert_alpha')
def _fog_vert_alpha(defines, measured):
    return ROOT, ['RigidMesh', 'FogPlane<true, VertexMaterialAlpha>']


def shift_tangent_frame():
    """A spec edit starting a deferred tangent frame one TEXCOORD later than measured."""
    import re
    from dataclasses import replace

    def edit(spec):
        if spec.entry != ROOT:
            return None
        out, hit = [], False
        for s in spec.specialize:
            m = re.search(r'TangentFrame<(\d+)', s) or re.search(r'Prepass<[^<>]*?(\d+)>', s)
            if m and not hit:
                s = s[:m.start(1)] + str(int(m.group(1)) + 1) + s[m.end(1):]
                hit = True
            out.append(s)
        return replace(spec, specialize=tuple(out)) if hit else None
    return edit


_PLACE = 'interfaces/surface_placement.slang'
_LIGHTS = 'math/surface_lights.slang'
_SURFACE = 'math/surface.slang'
_ROOT = 'roots/surface/surface_vs.slang'

#: gate D8 mutations for this workspace's roots, as dicts of d3_mutate.Mutation fields
MUTATIONS = [
    dict(name='surface-transport-width', root=ROOT, kind='cfg', spec=C.widen_first_row(), cls='transport'),
    dict(name='surface-bone-weight-swap', root=ROOT, kind='src', file=_PLACE,
         old='float4 row0 = matBones[bones.x].row0 * weights.x + matBones[bones.y].row0 * weights.y',
         new='float4 row0 = matBones[bones.x].row0 * weights.y + matBones[bones.y].row0 * weights.x',
         cls='bone'),
    dict(name='surface-nan-cylinder-perp', root=ROOT, kind='src', file=_LIGHTS,
         old='float perp = sqrt(max(axisDist2 - along * along, 0.0));',
         new='float perp = sqrt(axisDist2 - along * along);', cls='nan'),
    dict(name='surface-light-clamp', root=ROOT, kind='src', file=_LIGHTS,
         old='int count = min(int(numLights.x), 16);', new='int count = min(int(numLights.x), 15);'),
    dict(name='surface-spot-cone-width', root=ROOT, kind='src', file=_LIGHTS,
         old='(lightSpots[s].radii.w - lightSpots[s].radii.z)', new='(lightSpots[s].radii.w + lightSpots[s].radii.z)'),
    dict(name='surface-sun-gate', root=ROOT, kind='src', file=_LIGHTS,
         old='l.sunDiffuse = (1.0 - lightPoints[0].wp.w) * primaryDiffuse;',
         new='l.sunDiffuse = lightPoints[0].wp.w * primaryDiffuse;'),
    dict(name='surface-frame-first', root=ROOT, kind='cfg', spec=shift_tangent_frame()),
    dict(name='surface-sway-phase', root=ROOT, kind='src', file=_PLACE,
         old='sin(sway.w + randFloat.w + randFloat.y)', new='sin(sway.w + randFloat.w + randFloat.x)'),
    dict(name='surface-curve-sway-axes', root=ROOT, kind='src', file=_PLACE,
         old='appearanceFX.xxy', new='appearanceFX.xyy'),
    dict(name='surface-reflection-shift', root=ROOT, kind='src', file=_SURFACE,
         old='clip.w * float2(shiftRow0.w, shiftRow1.w)', new='float2(shiftRow0.w, shiftRow1.w)'),
    dict(name='surface-two-sided-flip', root=ROOT, kind='src', file=_ROOT,
         old='normal.z < 0.0 ? -normal : normal', new='normal.z > 0.0 ? -normal : normal'),
    dict(name='surface-near-fade-depth', root=ROOT, kind='src', file='interfaces/vertex_alpha.slang',
         old='saturate(v.clip.z * 0.025)', new='saturate(v.clip.z * 0.05)'),
    dict(name='surface-floor-fade-width', root=ROOT, kind='src', file=_ROOT,
         old='d3FadeOut(playerDistance, 15.0, 35.0)', new='d3FadeOut(playerDistance, 15.0, 45.0)'),
    dict(name='surface-side-projection-z', root=ROOT, kind='src', file=_ROOT,
         old='-v.world.z * scale', new='v.world.z * scale'),
    dict(name='surface-water-eye-vector', root=ROOT, kind='src', file=_ROOT,
         old='normalize(wpViewPos.xyz - v.world.xyz)', new='normalize(wpPlayer.xyz - v.world.xyz)'),
    dict(name='surface-water-layer-rows', root=ROOT, kind='src', file=_ROOT,
         old='d3TexTransform(matTex5[0], matTex5[1], uv).xyxy', new='d3TexTransform(matTex5[0], matTex5[1], uv).yxyx'),
    dict(name='surface-overlay-fade-radius', root=ROOT, kind='src', file=_ROOT,
         old='lightCylindricals[0].radii.y * 0.6', new='lightCylindricals[0].radii.x * 0.6'),
    dict(name='surface-fog-plane-ambient', root=ROOT, kind='src', file=_ROOT,
         old='o.setTexcoord0(float4((color * 2.0 + light.ambient) * 0.5, alpha));',
         new='o.setTexcoord0(float4((color * 2.0 + light.diffuse) * 0.5, alpha));'),
]

#: roots that must include a tie-flip / bone-order mutation
ALPHA_ROOTS = []
SKINNED_ROOTS = [ROOT]
