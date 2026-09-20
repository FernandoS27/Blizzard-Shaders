// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// The fixed-function texture-stage combiner.
//
// Diablo III emulates the D3D9 texture-stage cascade in its legacy, billboard
// and flow pixel shaders: a chain starts from a head value, then each stage
// samples one texture unit and folds it into the running colour and alpha with
// one combine operation per channel. What a stage does to a channel is one
// **op word**, a bitfield the translators emit as a number:
//
//   op        OP_SKIP / OP_MOD (v * src) / OP_ADD (v + src) /
//             OP_MOD_INVALPHA_ADD (v * (1 - tex.a) + tex.rgb, D3DTOP_MODULATEINVALPHA_ADDCOLOR)
//   source    FROM_ALPHA replicates the texture alpha into rgb
//   modifiers VCOLOR / VCOLOR_A / FACTOR / FACTOR_A / APPFX multiply the result by
//             the vertex colour (its alpha), Factor (its w) or appearanceFX.x, in
//             that order -- or appearanceFX before Factor with APPFX_BEFORE_FACTOR
//   gain      GAIN_2X / GAIN_4X on the modified value (D3DTOP_MODULATE2X / 4X)
//   adds      ADD_VCOLOR / ADD_FACTOR add the vertex colour / Factor
//   SAT       clamps before the next stage reads the value
//   POST_*    modifiers applied only after that clamp -- a different number,
//             so a flag rather than a reordering
//
// Multiplications inside one stage (and across a run of modulating stages)
// commute as real numbers, so where a modifier sits inside such a run changes
// only float32 rounding; the clamp that ends a run, and what comes after it,
// changes the value. Rounding still separates retail programs -- an alpha test
// sees the exact bits -- which is why modifier order is part of the word.

implementing d3_shaders;

// ---------------------------------------------------------------------------
// Op word
// ---------------------------------------------------------------------------

public static const uint OP_MASK = 3;
public static const uint OP_SKIP = 0;
public static const uint OP_MOD = 1;
public static const uint OP_ADD = 2;
public static const uint OP_MOD_INVALPHA_ADD = 3;

public static const uint GAIN_MASK = 12;
public static const uint GAIN_2X = 4;
public static const uint GAIN_4X = 8;

public static const uint FROM_ALPHA = 16;

public static const uint VCOLOR = 64;
public static const uint VCOLOR_A = 128;
public static const uint FACTOR = 256;
public static const uint FACTOR_A = 512;
public static const uint APPFX = 1024;

public static const uint ADD_VCOLOR = 2048;
public static const uint ADD_FACTOR = 4096;

public static const uint SAT = 8192;

public static const uint POST_FACTOR = 16384;
public static const uint POST_FACTOR_A = 32768;
public static const uint POST_APPFX = 65536;

public static const uint APPFX_BEFORE_FACTOR = 131072;

bool d3OpHas(uint op, uint flag) { return (op & flag) != 0; }

float3 d3Gain(float3 v, uint op)
{
    uint g = op & GAIN_MASK;
    if (g == GAIN_2X) return v + v;
    if (g == GAIN_4X) return v * 4.0;
    return v;
}

float d3Gain(float v, uint op)
{
    uint g = op & GAIN_MASK;
    if (g == GAIN_2X) return v + v;
    if (g == GAIN_4X) return v * 4.0;
    return v;
}

/// The modifiers of an op word multiplied into a colour.
float3 d3ModifyRgb(float3 v, uint op, float4 color0)
{
    if (d3OpHas(op, VCOLOR))   v *= color0.rgb;
    if (d3OpHas(op, VCOLOR_A)) v *= color0.a;
    bool appfxFirst = d3OpHas(op, APPFX_BEFORE_FACTOR);
    if (appfxFirst && d3OpHas(op, APPFX)) v *= appearanceFX.x;
    if (d3OpHas(op, FACTOR))   v *= Factor.rgb;
    if (d3OpHas(op, FACTOR_A)) v *= Factor.w;
    if (!appfxFirst && d3OpHas(op, APPFX)) v *= appearanceFX.x;
    return v;
}

/// The modifiers of an op word multiplied into an alpha.
float d3ModifyAlpha(float v, uint op, float4 color0)
{
    if (d3OpHas(op, VCOLOR))   v *= color0.a;
    if (d3OpHas(op, VCOLOR_A)) v *= color0.a;
    bool appfxFirst = d3OpHas(op, APPFX_BEFORE_FACTOR);
    if (appfxFirst && d3OpHas(op, APPFX)) v *= appearanceFX.x;
    if (d3OpHas(op, FACTOR))   v *= Factor.w;
    if (d3OpHas(op, FACTOR_A)) v *= Factor.w;
    if (!appfxFirst && d3OpHas(op, APPFX)) v *= appearanceFX.x;
    return v;
}

/// The head of a chain: 1, times the modifiers and gain, optionally clamped.
float3 d3HeadRgb(uint op, float4 color0)
{
    float3 v = d3Gain(d3ModifyRgb(float3(1.0, 1.0, 1.0), op, color0), op);
    if (d3OpHas(op, SAT)) v = saturate(v);
    return v;
}

float d3HeadAlpha(uint op, float4 color0)
{
    float v = d3Gain(d3ModifyAlpha(1.0, op, color0), op);
    if (d3OpHas(op, SAT)) v = saturate(v);
    return v;
}

/// One stage's combine on the colour channel.
float3 d3StageRgb(float3 v, float4 tex, uint op, float4 color0)
{
    uint kind = op & OP_MASK;
    if (kind == OP_SKIP)
        return v;
    if (kind == OP_MOD_INVALPHA_ADD)
    {
        float inv = tex.a;
        if (d3OpHas(op, APPFX)) inv *= appearanceFX.x;
        v = v * (1.0 - inv) + tex.rgb;
    }
    else
    {
        float3 src = d3OpHas(op, FROM_ALPHA) ? tex.aaa : tex.rgb;
        v = d3Gain(d3ModifyRgb(kind == OP_ADD ? v + src : v * src, op, color0), op);
        if (d3OpHas(op, ADD_VCOLOR)) v += color0.rgb;
        if (d3OpHas(op, ADD_FACTOR)) v += Factor.rgb;
    }
    if (d3OpHas(op, SAT))           v = saturate(v);
    if (d3OpHas(op, POST_FACTOR))   v *= Factor.rgb;
    if (d3OpHas(op, POST_FACTOR_A)) v *= Factor.w;
    if (d3OpHas(op, POST_APPFX))    v *= appearanceFX.x;
    return v;
}

/// One stage's combine on the alpha channel.
float d3StageAlpha(float v, float4 tex, uint op, float4 color0)
{
    uint kind = op & OP_MASK;
    if (kind == OP_SKIP)
        return v;
    v = d3Gain(d3ModifyAlpha(kind == OP_ADD ? v + tex.a : v * tex.a, op, color0), op);
    if (d3OpHas(op, ADD_VCOLOR)) v += color0.a;
    if (d3OpHas(op, ADD_FACTOR)) v += Factor.w;
    if (d3OpHas(op, SAT))           v = saturate(v);
    if (d3OpHas(op, POST_FACTOR))   v *= Factor.w;
    if (d3OpHas(op, POST_FACTOR_A)) v *= Factor.w;
    if (d3OpHas(op, POST_APPFX))    v *= appearanceFX.x;
    return v;
}

// ---------------------------------------------------------------------------
// Texture units
// ---------------------------------------------------------------------------

/// What every stage reads: the vertex colour and the texture coordinate of
/// each unit (already displaced, when a flow front displaces it).
public struct D3StageArgs
{
    public float4 color0;
    public float2 uv0;
    public float2 uv1;
    public float2 uv2;
    public float2 uv3;
    public float2 uv4;
    public float2 uv5;

    public float2 uv(int unit)
    {
        if (unit == 0) return uv0;
        if (unit == 1) return uv1;
        if (unit == 2) return uv2;
        if (unit == 3) return uv3;
        if (unit == 4) return uv4;
        return uv5;
    }
};

/// The interpolated texture coordinate of one unit.
public float2 d3UnitTexcoord(D3Interpolants i, int unit)
{
    if (unit == 0) return i.texcoord0().xy;
    if (unit == 1) return i.texcoord1().xy;
    if (unit == 2) return i.texcoord2().xy;
    if (unit == 3) return i.texcoord3().xy;
    if (unit == 4) return i.texcoord4().xy;
    return i.texcoord5().xy;
}

/// The texture a unit is bound to, by its retail role. Its register is the
/// slot's measured data (types/textures.slang), so the role only names it.
public interface ITextureRole
{
    static float4 sample(float2 uv);
}

public struct Sampler0 : ITextureRole { public static float4 sample(float2 uv) { return sampler0.Sample(sampler0_s, uv); } };
public struct Sampler1 : ITextureRole { public static float4 sample(float2 uv) { return sampler1.Sample(sampler1_s, uv); } };
public struct Sampler2 : ITextureRole { public static float4 sample(float2 uv) { return sampler2.Sample(sampler2_s, uv); } };
public struct Sampler3 : ITextureRole { public static float4 sample(float2 uv) { return sampler3.Sample(sampler3_s, uv); } };
public struct Sampler4 : ITextureRole { public static float4 sample(float2 uv) { return sampler4.Sample(sampler4_s, uv); } };
public struct Sampler5 : ITextureRole { public static float4 sample(float2 uv) { return sampler5.Sample(sampler5_s, uv); } };
public struct DiffuseSampler : ITextureRole { public static float4 sample(float2 uv) { return diffuseSampler.Sample(diffuseSampler_s, uv); } };
public struct DiffuseSampler1 : ITextureRole { public static float4 sample(float2 uv) { return diffuseSampler1.Sample(diffuseSampler1_s, uv); } };
public struct DiffuseSampler2 : ITextureRole { public static float4 sample(float2 uv) { return diffuseSampler2.Sample(diffuseSampler2_s, uv); } };
public struct FlowSampler : ITextureRole { public static float4 sample(float2 uv) { return flowSampler.Sample(flowSampler_s, uv); } };
public struct FlowSampler1 : ITextureRole { public static float4 sample(float2 uv) { return flowSampler1.Sample(flowSampler1_s, uv); } };
public struct FlowSampler2 : ITextureRole { public static float4 sample(float2 uv) { return flowSampler2.Sample(flowSampler2_s, uv); } };
public struct FlowSampler3 : ITextureRole { public static float4 sample(float2 uv) { return flowSampler3.Sample(flowSampler3_s, uv); } };

// ---------------------------------------------------------------------------
// Stages and chains
// ---------------------------------------------------------------------------

public interface ICombinerStage
{
    static void apply(inout float3 rgb, inout float alpha, D3StageArgs a);
}

/// A stage the pass does not set up.
public struct StageSkip : ICombinerStage
{
    public static void apply(inout float3 rgb, inout float alpha, D3StageArgs a) {}
};

/// One texture stage: unit UNIT read through role TTex, folded into colour
/// and alpha by the op words RGB and ALPHA.
public struct Stage<TTex : ITextureRole, let UNIT : int, let RGB : uint, let ALPHA : uint> : ICombinerStage
{
    public static void apply(inout float3 rgb, inout float alpha, D3StageArgs a)
    {
        float4 tex = TTex.sample(a.uv(UNIT));
        rgb = d3StageRgb(rgb, tex, RGB, a.color0);
        alpha = d3StageAlpha(alpha, tex, ALPHA, a.color0);
    }
};

/// Where a chain starts before its first stage.
public interface IChainHead
{
    static float3 rgb(D3StageArgs a);
    static float alpha(D3StageArgs a);
}

/// 1, times the head op words' modifiers and gain.
public struct Head<let RGB : uint, let ALPHA : uint> : IChainHead
{
    public static float3 rgb(D3StageArgs a) { return d3HeadRgb(RGB, a.color0); }
    public static float alpha(D3StageArgs a) { return d3HeadAlpha(ALPHA, a.color0); }
};

/// Alpha starts from the vertex alpha biased by Factor.w and clamped.
public struct HeadAlphaBias<let RGB : uint> : IChainHead
{
    public static float3 rgb(D3StageArgs a) { return d3HeadRgb(RGB, a.color0); }
    public static float alpha(D3StageArgs a) { return saturate(Factor.w + a.color0.a); }
};

public interface IStageChain
{
    static void run(out float3 rgb, out float alpha, D3StageArgs a);
}

/// A head and up to six stages, in pass order.
public struct StageChain<H : IChainHead, S0 : ICombinerStage, S1 : ICombinerStage, S2 : ICombinerStage,
                         S3 : ICombinerStage, S4 : ICombinerStage, S5 : ICombinerStage> : IStageChain
{
    public static void run(out float3 rgb, out float alpha, D3StageArgs a)
    {
        rgb = H.rgb(a);
        alpha = H.alpha(a);
        S0.apply(rgb, alpha, a);
        S1.apply(rgb, alpha, a);
        S2.apply(rgb, alpha, a);
        S3.apply(rgb, alpha, a);
        S4.apply(rgb, alpha, a);
        S5.apply(rgb, alpha, a);
    }
};

/// Two independently combined layers summed (`_blendadd`, `_dualsmoke`): each
/// optionally premultiplied by its own alpha, the extra layer added into the
/// base colour -- or, with INTO_ALPHA, only its alpha into the base alpha.
public struct LayerSum<TBase : IStageChain, TExtra : IStageChain,
                       let BASE_PREMULTIPLIED : bool, let EXTRA_PREMULTIPLIED : bool,
                       let INTO_ALPHA : bool> : IStageChain
{
    public static void run(out float3 rgb, out float alpha, D3StageArgs a)
    {
        TBase.run(rgb, alpha, a);
        float3 xrgb;
        float xalpha;
        TExtra.run(xrgb, xalpha, a);
        if (EXTRA_PREMULTIPLIED)
            xrgb *= xalpha;
        if (BASE_PREMULTIPLIED)
            rgb *= alpha;
        if (INTO_ALPHA)
            alpha += xalpha;
        else
            rgb += xrgb;
    }
};
