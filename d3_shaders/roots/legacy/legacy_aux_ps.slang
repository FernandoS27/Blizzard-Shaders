// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Auxiliary pixel passes drawn over legacy-layout meshes (Legacy.fx,
// Distortion.fx, Scene.fx): the depth prepass, the selection highlight and its
// eraser, the text highlight, projected premultiplied decal layers, two-layer
// screen distortion and the opaque glow surface.
//
// Each pass is one fixed computation: the features that tell their users apart
// (skinning, snapping, weather deform, wrap modes, the slowed distortion's
// extra interpolant) live in the paired vertex shader or in render state, and
// reach this stage only as the measured interpolant layout. The root is generic
// over the pass's pixel model, which produces colour and coverage, and over the
// alpha test applied to that coverage.

implementing d3_shaders;

public interface ILegacyAuxPixelModel
{
    static float4 shade(D3Interpolants i);
}

/// Depth / occlusion-query prepass: the colour target is masked, so the stage
/// writes constant transparent black.
public struct PrepassDepthOnly : ILegacyAuxPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        return float4(0.0, 0.0, 0.0, 0.0);
    }
};

/// Selection highlight / occluded silhouette: the flat highlight colour in
/// `Factor.rgb`, coverage from the diffuse cutout times vertex alpha times the
/// highlight intensity `Factor.w`.
public struct HighlightSilhouette : ILegacyAuxPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float cutout = texDiffuse.Sample(texDiffuse_s, i.texcoord0().xy).a;
        return float4(Factor.xyz, cutout * i.color0().w * Factor.w);
    }
};

/// Erases a previously drawn highlight: transparent black wherever the sprite
/// is opaque, and the sprite's cut-out (diffuse alpha below one half) clipped
/// so the highlight underneath survives.
public struct HighlightErase : ILegacyAuxPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float cutout = texDiffuse.Sample(texDiffuse_s, i.texcoord0().xy).a;
        clip(cutout - 0.5);
        return float4(0.0, 0.0, 0.0, 0.0);
    }
};

/// Text highlight: the vertex colour, with the glyph atlas' alpha as coverage
/// scaled by the vertex alpha.
public struct HighlightText : ILegacyAuxPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 tint = i.color0();
        float coverage = texDiffuse.Sample(texDiffuse_s, i.texcoord0().xy).a;
        return float4(tint.rgb, coverage * tint.a);
    }
};

/// A premultiplied layer that contributes nothing: black, fully transmissive.
static const float4 kNoProjectedLayer = float4(0.0, 0.0, 0.0, 1.0);

/// Projected premultiplied-alpha layer (decals, weather splats): the layer is
/// clipped to its projected unit box with a smoothstep fade over the outer
/// tenth, further limited by a mask texture, fogged in premultiplied space and
/// gated by the diffuse alpha times vertex alpha. TEXCOORD0 carries the
/// projected box coordinate in .xy and the fog factor in .z.
public struct ProjectedLayerPremultiplied : ILegacyAuxPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float3 projected = i.texcoord0().xyz;
        float2 box = 0.5 - abs(projected.xy - 0.5);
        clip(box);

        float2 edge = saturate(box * 10.0);
        float2 fade = edge * edge * (edge * -2.0 + 3.0);
        float coverage = min(fade.y, fade.x);
        coverage = min(coverage, pmaMaskTex.Sample(pmaMaskTex_s, i.texcoord2().xy).x);

        // Premultiplied colour over destination transmittance in .a: coverage
        // fades the layer towards "no layer" (black, fully transmissive).
        float4 layer = pmaTex.Sample(pmaTex_s, projected.xy);
        float4 covered = lerp(kNoProjectedLayer, layer, coverage);
        float alphaDelta = coverage * (layer.a - 1.0);

        float fog = projected.z;
        float3 fogged = lerp(fogColor.rgb, covered.rgb, fog) - (covered.a * fogColor.rgb) * (1.0 - fog);

        float gate = diffuseTex.Sample(diffuseTex_s, i.texcoord1().xy).a * i.color0().w;
        return float4(fogged * gate, gate * alphaDelta + 1.0);
    }
};

/// Two-layer screen distortion: the sum of two scrolled distortion samples,
/// biased so mid-grey is no displacement; vertex alpha gates the strength.
public struct DistortionTwoLayer : ILegacyAuxPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 layer0 = texLayer0.Sample(texLayer0_s, i.texcoord0().xy);
        float4 layer1 = texLayer1.Sample(texLayer1_s, i.texcoord1().xy);
        return float4(layer0.rgb + layer1.rgb - 0.5, i.color0().w);
    }
};

/// Opaque vertex-lit diffuse with an additive glow map scaled by
/// `appearanceFX.x`, then fog.
public struct OpaqueGlow : ILegacyAuxPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float2 uv = i.texcoord0().xy;
        float3 glow = glowSampler.Sample(glowSampler_s, uv).rgb * appearanceFX.x;
        float3 light = i.color0().rgb;
        float4 diffuse = diffuseSampler.Sample(diffuseSampler_s, uv);
        float3 lit = (light + light) * diffuse.rgb + glow;
        return float4(d3ApplyFog(lit, i.fog().x), diffuse.a);
    }
};

[shader("fragment")]
public float4 legacy_aux_ps_main<TModel : ILegacyAuxPixelModel, TAlpha : IAlphaTest>(D3Interpolants i) : SV_Target
{
    float4 color = TModel.shade(i);
    TAlpha.apply(color.a);
    return color;
}
