// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Scene pixel shaders: lightmapped world geometry, props and floors
// (Scene.fx, Prop.fx), their alpha prepasses, and the interactive fog planes
// (InteractiveFog.fx).
//
// The root is generic over the surface model, which produces the final colour
// and coverage, and over the alpha test applied to that coverage. The models
// live in scene_models.slang and are assembled from the shadow filters
// (scene_shadow.slang) and light rigs (scene_lighting.slang).

implementing d3_shaders;

public interface ISurfacePixelModel
{
    static float4 shade(D3Interpolants i);
}

/// The TEXCOORDn interpolant by index: where a surface's vertex stage put a
/// value depends on the features it packs ahead of it.
public float4 sceneTexcoord(D3Interpolants i, int n)
{
    switch (n)
    {
    case 0: return i.texcoord0();
    case 1: return i.texcoord1();
    case 2: return i.texcoord2();
    case 3: return i.texcoord3();
    case 4: return i.texcoord4();
    case 5: return i.texcoord5();
    case 6: return i.texcoord6();
    case 7: return i.texcoord7();
    case 8: return i.texcoord8();
    case 9: return i.texcoord9();
    case 10: return i.texcoord10();
    case 11: return i.texcoord11();
    case 12: return i.texcoord12();
    default: return i.texcoord13();
    }
}

// ---------------------------------------------------------------------------
// coverage shaping
// ---------------------------------------------------------------------------

/// What the surface does to its coverage before the alpha test.
public interface IAlphaShape
{
    static float shape(float alpha);
}

public struct AlphaUnshaped : IAlphaShape
{
    public static float shape(float alpha) { return alpha; }
};

/// Coverage posterized to quarter steps above 0.34375 (the foliage alpha
/// mask): `saturate(ceil((a - 0.34375) * 64/7) / 4)`.
public struct AlphaQuarterStepsSoft : IAlphaShape
{
    public static float shape(float alpha)
    {
        return saturate(ceil((alpha - 0.34375) * 9.1428575) * 0.25);
    }
};

/// Coverage posterized to quarter steps above one half (the multipass prop
/// mask): `saturate(ceil((a - 0.5) * 12) / 4)`.
public struct AlphaQuarterStepsHard : IAlphaShape
{
    public static float shape(float alpha)
    {
        return saturate(ceil((alpha - 0.5) * 12.0) * 0.25);
    }
};

// ---------------------------------------------------------------------------
// depth prepasses
// ---------------------------------------------------------------------------

/// Alpha-tested depth prepass: black, with the diffuse coverage times the
/// vertex alpha. `UV` is the TEXCOORD the diffuse coordinate arrives in.
public struct CoveragePrepass<TShape : IAlphaShape, let UV : int> : ISurfacePixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 diffuse = diffuseSampler.Sample(diffuseSampler_s, sceneTexcoord(i, UV).xy);
        return float4(0.0, 0.0, 0.0, TShape.shape(diffuse.a * i.color0().a));
    }
};

// ---------------------------------------------------------------------------
// interactive fog planes
// ---------------------------------------------------------------------------

/// A scrolling fog plane: three alpha masks (doubled) carve the silhouette,
/// the fog map's red channel erodes it, the third mask's colour tints it.
/// With VERTEX_ALPHA the vertex colour carries a coverage factor instead of a
/// tint.
public struct FogPlaneMasks<let VERTEX_ALPHA : bool> : ISurfacePixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float mask0 = alphaMap0Sampler.Sample(alphaMap0Sampler_s, i.texcoord1().xy).a;
        float mask1 = alphaMap1Sampler.Sample(alphaMap1Sampler_s, i.texcoord2().xy).a;
        float4 shape = alphaMap2Sampler.Sample(alphaMap2Sampler_s, i.texcoord3().xy);
        float solid = 1.0 - fogSampler.Sample(fogSampler_s, i.texcoord4().xy).r;

        float alpha = 2.0 * (mask0 * mask1) * shape.a * solid;
        float3 tint = shape.rgb;
        if (VERTEX_ALPHA)
            alpha = alpha * i.color0().a;
        else
            tint = (2.0 * i.color0().rgb) * shape.rgb;
        return float4(d3ApplyFog(tint, i.fog().x), alpha);
    }
};

// ---------------------------------------------------------------------------
// root
// ---------------------------------------------------------------------------

[shader("fragment")]
public float4 scene_ps_main<TModel : ISurfacePixelModel, TAlpha : IAlphaTest>(D3Interpolants i) : SV_Target
{
    float4 color = TModel.shade(i);
    TAlpha.apply(color.a);
    return color;
}
