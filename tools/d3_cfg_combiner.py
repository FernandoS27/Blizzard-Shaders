"""Translators for the stage-combiner pixel root (combiner_ps_main).

Ten retail subfamilies spell the same machine five ways: Legacy's op-word
bitfield (``S<n>_RGB = "MOD_2X|VCOLOR|SAT"``), Billboard's ``{op, gain, clamp}``
tokens (``MOD_2X_SAT``) with a vertex-colour placement, SoftBillboard's
``{op, gain}``, the flow families' own mode numbers, and one program with no
defines at all. Every translator below builds the same :class:`Combiner` --
flow front, stage chain in Legacy's op words, resolve steps -- and one function
turns it into the spec, so a program shared by two subfamilies (19 of them)
gets one spec from either spelling (gate D1).
"""

from dataclasses import dataclass, field

import d3_shaders_cfg as C
from d3_shaders_cfg import translator, on

ROOT = 'combiner_ps_main'

# --------------------------------------------------------------------------
# op words (interfaces/combiner.slang)
# --------------------------------------------------------------------------

OP_MASK, SKIP, MOD, ADD, MIA = 3, 0, 1, 2, 3
GAIN_2X, GAIN_4X = 4, 8
FROM_ALPHA = 16
VCOLOR, VCOLOR_A, FACTOR, FACTOR_A, APPFX = 64, 128, 256, 512, 1024
ADD_VCOLOR, ADD_FACTOR = 2048, 4096
SAT = 8192
POST_FACTOR, POST_FACTOR_A, POST_APPFX = 16384, 32768, 65536
APPFX_BEFORE_FACTOR = 131072
MODIFIERS = VCOLOR | VCOLOR_A | FACTOR | FACTOR_A | APPFX | APPFX_BEFORE_FACTOR

#: Legacy.fx's manifest tokens
LEGACY_TOKENS = {
    'SKIP': SKIP, 'OP_SKIP': SKIP, 'MOD': MOD, 'OP_MOD': MOD, 'ADD': ADD, 'OP_ADD': ADD,
    'MOD_INVALPHA_ADD': MIA, 'OP_MIA': MIA,
    'MOD_2X': MOD | GAIN_2X, 'MOD_4X': MOD | GAIN_4X, 'ADD_2X': ADD | GAIN_2X, 'ADD_4X': ADD | GAIN_4X,
    'GAIN_1X': 0, 'GAIN_2X': GAIN_2X, 'GAIN_4X': GAIN_4X, 'FROM_ALPHA': FROM_ALPHA,
    'VCOLOR': VCOLOR, 'VCOLOR_A': VCOLOR_A, 'FACTOR': FACTOR, 'FACTOR_A': FACTOR_A, 'APPFX': APPFX,
    'ADD_VCOLOR': ADD_VCOLOR, 'ADD_FACTOR': ADD_FACTOR, 'SAT': SAT,
    'POST_FACTOR': POST_FACTOR, 'POST_FACTOR_A': POST_FACTOR_A, 'POST_APPFX': POST_APPFX,
}

#: Billboard.fx / SoftBillboard.fx {op, gain, clamp} tokens
BILLBOARD_TOKENS = {
    'SKIP': SKIP, 'MOD': MOD, 'MOD_SAT': MOD | SAT, 'MOD_2X': MOD | GAIN_2X, 'MOD_2X_SAT': MOD | GAIN_2X | SAT,
    'MOD_4X': MOD | GAIN_4X, 'MOD_4X_SAT': MOD | GAIN_4X | SAT, 'ADD': ADD, 'ADD_SAT': ADD | SAT,
}

# resolve steps (roots/legacy/combiner_ps.slang)
EROSION, VCOLOR_RGB_LAST, VCOLOR_ALPHA_LAST = 1, 2, 4
SQUARE_RGB, SQUARE_ALPHA, NEAR_FADE, SOFT_FADE, ZERO_RGB = 8, 16, 32, 64, 128
PREMULTIPLY = 256
ALPHA_KEEP, ALPHA_INVERSE, ALPHA_ONE, ALPHA_ZERO = 0, 512, 1024, 1536
FOG = 2048


# uint value generics are spelled with a U suffix: slangc (2026.x) crashes
# specializing a `let X : uint` from an unsuffixed integer literal.

def word(text, tokens: dict, head: bool = False) -> int:
    """One op word. Legacy's fit lists a stage's modifiers in the order retail
    multiplies them, which separates programs that differ only there; a head
    always multiplies appearanceFX before Factor."""
    names = [t.strip() for t in str(text).split('|') if t.strip()]
    w = 0
    for t in names:
        w |= int(t) if t.isdigit() else tokens[t]
    if (w & APPFX) and (w & (FACTOR | FACTOR_A)):
        factor = min(names.index(n) for n in ('FACTOR', 'FACTOR_A') if n in names)
        if head or names.index('APPFX') < factor:
            w |= APPFX_BEFORE_FACTOR
    return w


# --------------------------------------------------------------------------
# the canonical combiner
# --------------------------------------------------------------------------

@dataclass
class Stage:
    role: str
    unit: int
    rgb: int
    alpha: int


@dataclass
class Chain:
    stages: list = field(default_factory=list)
    head_rgb: int = 0
    head_alpha: int = 0
    alpha_bias: bool = False           # alpha starts at saturate(Factor.w + COLOR0.a)

    def normalized(self):
        """Legacy's fit folds a textureless first stage into the first textured
        one. Retail multiplies that stage's modifiers BEFORE the texture -- the
        head's place -- which rounds differently, and an alpha test sees it.
        The fold shows as a channel whose first texture is not unit 0 while the
        stage's other channel carries no modifiers of its own (a stage where
        both channels take the vertex colour is a real textured stage)."""
        for attr, other, head in (('rgb', 'alpha', 'head_rgb'), ('alpha', 'rgb', 'head_alpha')):
            for s in self.stages:
                w = getattr(s, attr)
                if (w & OP_MASK) == SKIP:
                    continue
                if (s.unit != 0 and (w & OP_MASK) == MOD and (w & MODIFIERS)
                        and not (getattr(s, other) & MODIFIERS)
                        and getattr(self, head) == 0 and not (attr == 'alpha' and self.alpha_bias)):
                    setattr(self, head, w & MODIFIERS)
                    setattr(s, attr, w & ~MODIFIERS)
                break
        return self

    def spec(self) -> str:
        self.normalized()
        head = ('HeadAlphaBias<%dU>' % self.head_rgb if self.alpha_bias
                else 'Head<%dU, %dU>' % (self.head_rgb, self.head_alpha))
        args = []
        for s in self.stages:
            if (s.rgb & OP_MASK) == SKIP and (s.alpha & OP_MASK) == SKIP:
                continue                                  # samples nothing anyone reads
            args.append('Stage<%s, %d, %dU, %dU>' % (s.role, s.unit, s.rgb, s.alpha))
        assert len(args) <= 6, args
        args += ['StageSkip'] * (6 - len(args))
        return 'StageChain<%s, %s>' % (head, ', '.join(args))

    def place_vertex_color(self, rgb: bool, alpha: bool) -> None:
        """COLOR0 as the chain's starting value: folded into the first stage
        that modulates that channel (multiplication commutes), else the head."""
        for want, attr, head in ((rgb, 'rgb', 'head_rgb'), (alpha, 'alpha', 'head_alpha')):
            if not want:
                continue
            for s in self.stages:
                w = getattr(s, attr)
                if (w & OP_MASK) == SKIP:
                    continue
                if (w & OP_MASK) == MOD:
                    setattr(s, attr, w | VCOLOR)
                else:
                    setattr(self, head, getattr(self, head) | VCOLOR)
                break
            else:
                setattr(self, head, getattr(self, head) | VCOLOR)


@dataclass
class LayerSum:
    base: Chain
    extra: Chain
    base_pma: bool
    extra_pma: bool
    into_alpha: bool

    def spec(self) -> str:
        b = lambda v: 'true' if v else 'false'
        return 'LayerSum<%s, %s, %s, %s, %s>' % (self.base.spec(), self.extra.spec(), b(self.base_pma),
                                                 b(self.extra_pma), b(self.into_alpha))


@dataclass
class Flow:
    maps: list            # [(role, unit)] 1..3
    units: int            # bit n: unit n is displaced

    def spec(self) -> str:
        maps = ['FlowMap<%s, %d>' % m for m in self.maps] + ['FlowMapNone'] * (3 - len(self.maps))
        return 'FlowWarp<%s, %dU>' % (', '.join(maps), self.units)


def alpha_test(measured: dict) -> str:
    """The retail alpha compare. A program whose written alpha is a constant
    has fxc fold the operand: ``lt ref, l(1)`` is the same test spelled on 1."""
    tests = [c.replace('lit', 'a') for c in measured['alphaCompare']]
    if not tests:
        return 'AlphaTestOff'
    assert len(set(tests)) == 1, tests
    return C._ALPHA[tests[-1]]


def spec(chain, measured: dict, steps: int = 0, flow: Flow | None = None):
    return ROOT, [flow.spec() if flow else 'FlowNone', chain.spec(), 'Resolve<%dU>' % steps,
                  alpha_test(measured)]


def fog(defines: dict) -> int:
    return FOG if on(defines, 'FOG') else 0


# --------------------------------------------------------------------------
# Legacy.fx ps_legacy: the op words as written
# --------------------------------------------------------------------------

_OUTPUT_ALPHA = {'ALPHA_KEEP': ALPHA_KEEP, 'ALPHA_INVERSE': ALPHA_INVERSE, 'ALPHA_ONE': ALPHA_ONE,
                 'ALPHA_ZERO': ALPHA_ZERO}


def _legacy_chain(d: dict, prefix: str, count: int) -> Chain:
    ch = Chain(head_rgb=word(d.get('HEAD_%sRGB' % prefix, 0), LEGACY_TOKENS, head=True),
               head_alpha=word(d.get('HEAD_%sALPHA' % prefix, 0), LEGACY_TOKENS, head=True))
    for n in range(count):
        unit = int(d.get('%sS%d_UNIT' % (prefix, n), n))
        default = 'MOD' if (n == 0 and not prefix) else 'SKIP'
        ch.stages.append(Stage('Sampler%d' % unit, unit,
                               word(d.get('%sS%d_RGB' % (prefix, n), default), LEGACY_TOKENS),
                               word(d.get('%sS%d_ALPHA' % (prefix, n), default), LEGACY_TOKENS)))
    return ch


@translator('Legacy.fx__ps_legacy')
def _legacy(d, measured):
    chain = _legacy_chain(d, '', int(d.get('STAGE_COUNT', 1)))
    if on(d, 'EXTRA_LAYER'):
        extra = _legacy_chain(d, 'X_', int(d.get('X_STAGE_COUNT', 0)))
        if on(d, 'BASE_PREMULTIPLIED') and on(d, 'PREMULTIPLIED'):
            # the output premultiply clamps alpha; the base layer premultiplies
            # by the value before that clamp
            last = [s for s in chain.stages if (s.alpha & OP_MASK) != SKIP][-1]
            last.alpha &= ~SAT
        chain = LayerSum(chain, extra, on(d, 'BASE_PREMULTIPLIED'), on(d, 'EXTRA_PREMULTIPLIED'),
                         d.get('EXTRA_ADDS', 'ADDS_RGB') == 'ADDS_ALPHA')
    steps = fog(d)
    steps |= SQUARE_RGB if on(d, 'RGB_SQUARE') else 0
    steps |= SQUARE_ALPHA if on(d, 'ALPHA_SQUARE') else 0
    steps |= NEAR_FADE if on(d, 'NEARFADE') else 0
    steps |= ZERO_RGB if on(d, 'RGB_ZERO') else 0
    steps |= PREMULTIPLY if on(d, 'PREMULTIPLIED') else 0
    steps |= _OUTPUT_ALPHA[d.get('OUTPUT_ALPHA', 'ALPHA_KEEP')]
    return spec(chain, measured, steps)


# --------------------------------------------------------------------------
# Billboard.fx / SoftBillboard.fx ps_legacy: {op, gain, clamp} + vertex colour
# --------------------------------------------------------------------------

_VCOL = {'VCOL_NONE': 0, 'VCOL_FIRST': 1, 'VCOL_LAST': 2, 'VCOL_BOTH': 3}


def _billboard_chain(d: dict, count: int) -> Chain:
    ch = Chain()
    for n in range(count):
        unit = int(d.get('S%d_UNIT' % n, n))
        default = 'MOD' if n == 0 else 'SKIP'
        ch.stages.append(Stage('Sampler%d' % unit, unit, word(d.get('S%d_RGB' % n, default), BILLBOARD_TOKENS),
                               word(d.get('S%d_ALPHA' % n, default), BILLBOARD_TOKENS)))
    return ch


@translator('Billboard.fx__ps_legacy')
def _billboard(d, measured):
    if on(d, 'BLENDADD'):
        # the base layer and an additive one from BLENDADD_UNIT, both
        # premultiplied; COLOR0 tints exactly one of them, and its alpha the base
        u0, ux = int(d.get('S0_UNIT', 0)), int(d.get('BLENDADD_UNIT', 3))
        on_extra = on(d, 'BLENDADD_VCOLOR_ON_EXTRA')
        base = Chain([Stage('Sampler%d' % u0, u0, MOD | (0 if on_extra else VCOLOR), MOD | VCOLOR)])
        extra = Chain([Stage('Sampler%d' % ux, ux, MOD | (VCOLOR if on_extra else 0),
                             MOD | (VCOLOR if on_extra else 0))])
        return spec(LayerSum(base, extra, True, True, False), measured)
    chain = _billboard_chain(d, int(d.get('STAGE_COUNT', 1)))
    vrgb = _VCOL[d.get('VCOLOR_RGB', 'VCOL_FIRST')]
    valpha = _VCOL[d.get('VCOLOR_ALPHA', 'VCOL_FIRST')]
    if on(d, 'ALPHA_BIAS_FACTOR'):
        chain.alpha_bias = True
        valpha &= ~1
    chain.place_vertex_color(bool(vrgb & 1), bool(valpha & 1))
    steps = fog(d)
    steps |= EROSION if on(d, 'EROSION') else 0
    steps |= VCOLOR_RGB_LAST if vrgb & 2 else 0
    steps |= VCOLOR_ALPHA_LAST if valpha & 2 else 0
    steps |= SQUARE_RGB if on(d, 'COLOR_SQUARE') else 0
    if on(d, 'PREMULTIPLIED'):
        steps |= PREMULTIPLY | (ALPHA_ONE if on(d, 'PMA_WRITES_ONE') else ALPHA_INVERSE)
    return spec(chain, measured, steps)


@translator('SoftBillboard.fx__ps_legacy')
def _soft_billboard(d, measured):
    chain = _billboard_chain(d, int(d.get('STAGE_COUNT', 1)))
    chain.place_vertex_color(True, True)
    return spec(chain, measured, fog(d) | SOFT_FADE)


# --------------------------------------------------------------------------
# flow families
# --------------------------------------------------------------------------

@translator('Billboard.fx__ps_firewall_flow', 'Legacy.fx__ps_firewall_flow')
def _firewall_flow(d, measured):
    # three layers scrolled by one flow map on unit 3: the base tinted by
    # COLOR0, colour from the base and layer 2, alpha from all three, doubled
    chain = Chain([Stage('Sampler0', 0, MOD | VCOLOR, MOD | VCOLOR),
                   Stage('Sampler1', 1, SKIP, MOD),
                   Stage('Sampler2', 2, MOD, MOD | GAIN_2X)])
    return spec(chain, measured, fog(d), Flow([('FlowSampler', 3)], 0b0111))


@translator('Billboard.fx__ps_particle_flow', 'Legacy.fx__ps_particle_flow')
def _particle_flow(d, measured):
    layers = 3 if (on(d, 'FLOW_MULT_MASKED') or int(d.get('FLOW_LAYERS', 1)) == 3) else 1
    maps = [('FlowSampler', 1), ('FlowSampler2', 2), ('FlowSampler3', 3)][:layers]
    chain = Chain([Stage('DiffuseSampler', 0, MOD | VCOLOR, MOD | VCOLOR)])
    return spec(chain, measured, fog(d), Flow(maps, 0b0001))


_FLOW_COLOR = {0: SKIP, 1: MOD, 2: MOD | GAIN_2X, 3: MOD | GAIN_2X | SAT}


@translator('Billboard.fx__ps_legacy_flow')
def _legacy_flow(d, measured):
    # two layers scrolled by one or two flow maps (units 2, 3): the base
    # tinted by COLOR0, the second layer's colour and alpha by mode
    amode = int(d.get('ALPHA_MODE', 3))
    chain = Chain([Stage('DiffuseSampler1', 0, MOD | VCOLOR, MOD | VCOLOR),
                   Stage('DiffuseSampler2', 1, _FLOW_COLOR[int(d.get('COLOR_MODE', 2))],
                         MOD | (GAIN_4X if amode & 2 else 0) | (SAT if amode & 1 else 0))])
    maps = [('FlowSampler1', 2)] + ([('FlowSampler2', 3)] if on(d, 'FLOW_MULT') else [])
    steps = fog(d) | ((PREMULTIPLY | ALPHA_INVERSE) if on(d, 'PREMULTIPLY') else 0)
    return spec(chain, measured, steps, Flow(maps, 0b0011))


@translator('Billboard.fx__ps_billboard_blendAdd_flowMult')
def _blend_add_flow(d, measured):
    # both layers premultiplied and summed, the second tinted by COLOR0, the
    # whole faded by COLOR0.a
    base = Chain([Stage('DiffuseSampler1', 0, MOD, MOD | VCOLOR)])
    extra = Chain([Stage('DiffuseSampler2', 1, MOD | VCOLOR, MOD | VCOLOR)])
    maps = [('FlowSampler1', 2)] + ([('FlowSampler2', 3)] if on(d, 'FLOW_MULT') else [])
    return spec(LayerSum(base, extra, True, True, False), measured, 0, Flow(maps, 0b0011))


@translator('Legacy.fx__ps_legacy_Malthael_wings_flow')
def _wings_flow(d, measured):
    # colour and two masks scrolled by two flow maps (units 4, 5); an
    # unscrolled gate mask on unit 3
    chain = Chain([Stage('Sampler0', 0, SKIP, MOD | GAIN_2X | VCOLOR | SAT),
                   Stage('Sampler1', 1, MOD | VCOLOR, MOD),
                   Stage('Sampler2', 2, MOD, MOD | GAIN_4X),
                   Stage('Sampler3', 3, SKIP, MOD | GAIN_4X)])
    return spec(chain, measured, 0, Flow([('FlowSampler1', 4), ('FlowSampler2', 5)], 0b0111))


# --------------------------------------------------------------------------
# gate D8
# --------------------------------------------------------------------------

def _clear_word_bit(bit: int):
    """A spec edit clearing one op-word bit wherever a specialization sets it."""
    import re
    from dataclasses import replace

    def edit(s):
        new = tuple(re.sub(r'\b(\d+)U\b', lambda m: '%dU' % (int(m.group(1)) & ~bit), x) for x in s.specialize)
        return replace(s, specialize=new) if new != s.specialize else None
    return edit


_COMBINER = 'interfaces/combiner.slang'
_FLOW = 'interfaces/flow.slang'
_PS = 'roots/legacy/combiner_ps.slang'

MUTATIONS = [
    # required classes
    dict(name='combiner-transport-width', root=ROOT, kind='cfg', spec=C.widen_first_row(), cls='transport'),
    dict(name='combiner-register-shift', root=ROOT, kind='cfg', spec=C.shift_first_texture(), cls='register'),
    dict(name='combiner-tie-flip', root=ROOT, kind='cfg', spec=C.swap_specialize('DiscardLE', 'DiscardLT'),
         cls='tie'),
    dict(name='combiner-nan-injection', root=ROOT, kind='src', file=_COMBINER,
         old='VCOLOR))   v *= color0.a;', new='VCOLOR))   v *= sqrt(color0.a - 0.5);', cls='nan'),
    # float32 rounding axis: only the alpha test's tie trials can see it
    dict(name='combiner-appfx-order', root=ROOT, kind='cfg', spec=_clear_word_bit(APPFX_BEFORE_FACTOR)),
    # op word semantics
    dict(name='stage-alpha-clamp-dropped', root=ROOT, kind='src', file=_COMBINER,
         old='if (d3OpHas(op, ADD_FACTOR)) v += Factor.w;\n    if (d3OpHas(op, SAT))           v = saturate(v);',
         new='if (d3OpHas(op, ADD_FACTOR)) v += Factor.w;'),
    dict(name='stage-invalpha-mask', root=ROOT, kind='src', file=_COMBINER,
         old='v = v * (1.0 - inv) + tex.rgb;', new='v = v * inv + tex.rgb;'),
    dict(name='head-alpha-bias-channel', root=ROOT, kind='src', file=_COMBINER,
         old='saturate(Factor.w + a.color0.a)', new='saturate(Factor.z + a.color0.a)'),
    dict(name='layer-sum-base-alpha', root=ROOT, kind='src', file=_COMBINER,
         old='            rgb *= alpha;', new='            rgb *= xalpha;'),
    # flow front and resolve tails
    dict(name='flow-offset-scale', root=ROOT, kind='src', file=_FLOW,
         old='float2 offset = (flow - 0.5) * 0.5;', new='float2 offset = (flow - 0.5) * 0.25;'),
    dict(name='soft-fade-range', root=ROOT, kind='src', file=_PS,
         old='static const float kSoftFadeRange = 2.0;', new='static const float kSoftFadeRange = 3.0;'),
    dict(name='erosion-exponent', root=ROOT, kind='src', file=_PS,
         old='pow(alpha, 10.0 * i.color1().a)', new='pow(alpha, 8.0 * i.color1().a)'),
    dict(name='near-fade-scale', root=ROOT, kind='src', file=_PS,
         old='saturate(0.025 * i.texcoord6().x)', new='saturate(0.05 * i.texcoord6().x)'),
    dict(name='premultiply-unclamped', root=ROOT, kind='src', file=_PS,
         old='rgb *= saturate(alpha);', new='rgb *= alpha;'),
]

ALPHA_ROOTS = [ROOT]
SKINNED_ROOTS = []
