// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Terrain pixel shaders (Landscape.fx): floors and ground built from splatted
// texture layers, lit by baked vertex light or per pixel, shadowed by the sun
// and the light map, optionally glossy, then fogged.
//
// The root is generic over how the layers combine into an albedo (and a
// normal-map normal), where the light comes from, the sun shadow filter, the
// ambient occlusion source, the gloss term and the alpha test.

implementing d3_shaders;

// ---------------------------------------------------------------------------
// Layers
// ---------------------------------------------------------------------------

/// What the layer blend produced for one pixel.
public struct LandscapeAlbedo
{
    /// the blended diffuse colour; alpha masks the gloss term
    public float4 color;
    /// the splat weights, reused to blend the normal maps
    public float4 weights;
    /// the over-composite coverage of the foreground layers
    public float coverage;
    /// a second, unlit layer composited over the lit result
    public float4 overlay;
};

public interface ILandscapeLayers
{
    static LandscapeAlbedo sample(D3Interpolants i);
    /// The tangent-space normal blended from the layers' normal maps.
    static float3 tangentNormal(D3Interpolants i, LandscapeAlbedo albedo);
    /// The lit albedo.
    static float3 shade(LandscapeAlbedo albedo, float3 lighting);
}

/// Five layers splatted by successive lerps: layer0 is the base, and texAlpha's
/// rgba lays layers 1-4 over it in turn. UVs: TEXCOORD1 (layers 0, 1),
/// TEXCOORD2 (2, 3), TEXCOORD3 (layer 4, weights). Each layer's normal map has
/// its own sampler.
public struct LayerSplat5 : ILandscapeLayers
{
    public static LandscapeAlbedo sample(D3Interpolants i)
    {
        LandscapeAlbedo a;
        a.weights = texAlpha.Sample(texAlpha_s, i.texcoord3().zw);
        float4 c = texLayer0.Sample(texLayer0_s, i.texcoord1().xy);
        c = lerp(c, texLayer1.Sample(texLayer1_s, i.texcoord1().zw), a.weights.x);
        c = lerp(c, texLayer2.Sample(texLayer2_s, i.texcoord2().xy), a.weights.y);
        c = lerp(c, texLayer3.Sample(texLayer3_s, i.texcoord2().zw), a.weights.z);
        c = lerp(c, texLayer4.Sample(texLayer4_s, i.texcoord3().xy), a.weights.w);
        a.color = c;
        a.coverage = 1.0;
        a.overlay = 0.0;
        return a;
    }
    public static float3 tangentNormal(D3Interpolants i, LandscapeAlbedo a)
    {
        float3 n = landscapeDecodeNormal(texNormal0.Sample(texNormal0_s, i.texcoord1().xy));
        n = lerp(n, landscapeDecodeNormal(texNormal1.Sample(texNormal1_s, i.texcoord1().zw)), a.weights.x);
        n = lerp(n, landscapeDecodeNormal(texNormal2.Sample(texNormal2_s, i.texcoord2().xy)), a.weights.y);
        n = lerp(n, landscapeDecodeNormal(texNormal3.Sample(texNormal3_s, i.texcoord2().zw)), a.weights.z);
        n = lerp(n, landscapeDecodeNormal(texNormal4.Sample(texNormal4_s, i.texcoord3().xy)), a.weights.w);
        return n;
    }
    public static float3 shade(LandscapeAlbedo a, float3 lighting) { return lighting * a.color.rgb; }
};

/// The five-layer splat with a side projection blended in over steep faces:
/// texCrossU / texCrossV projected along the two horizontal axes (TEXCOORD7.yz,
/// .xz), weighted by TEXCOORD6.zw, and faded over the slope factor TEXCOORD7.w
/// in [0.57, 0.70] with a smoothstep. The normal maps share the layer samplers.
public struct LayerSplat5SideProjected : ILandscapeLayers
{
    public static LandscapeAlbedo sample(D3Interpolants i)
    {
        LandscapeAlbedo a = LayerSplat5.sample(i);
        float4 crossV = texCrossV.Sample(texCrossV_s, i.texcoord7().xz);
        float4 crossU = texCrossU.Sample(texCrossU_s, i.texcoord7().yz);
        float4 side = crossU * i.texcoord6().z + crossV * i.texcoord6().w;
        float slope = saturate((i.texcoord7().w - 0.57) * 7.6923075);
        a.color = lerp(side, a.color, (slope * slope) * (3.0 - 2.0 * slope));
        return a;
    }
    public static float3 tangentNormal(D3Interpolants i, LandscapeAlbedo a)
    {
        float3 n = landscapeDecodeNormal(texNormal0.Sample(texLayer0_s, i.texcoord1().xy));
        n = lerp(n, landscapeDecodeNormal(texNormal1.Sample(texLayer1_s, i.texcoord1().zw)), a.weights.x);
        n = lerp(n, landscapeDecodeNormal(texNormal2.Sample(texLayer2_s, i.texcoord2().xy)), a.weights.y);
        n = lerp(n, landscapeDecodeNormal(texNormal3.Sample(texLayer3_s, i.texcoord2().zw)), a.weights.z);
        n = lerp(n, landscapeDecodeNormal(texNormal4.Sample(texLayer4_s, i.texcoord3().xy)), a.weights.w);
        return n;
    }
    public static float3 shade(LandscapeAlbedo a, float3 lighting) { return lighting * a.color.rgb; }
};

/// Layers 0-3 composited front to back by their coverage (splat weight times
/// layer alpha), normalised by the total coverage and laid over layer 4 as the
/// background. Zero coverage divides by zero, as retail does.
public struct LayerOver5 : ILandscapeLayers
{
    static float3 over(float3 c0, float3 c1, float3 c2, float3 c3, float3 c4, float4 w, float coverage)
    {
        float3 front = lerp(w.x * c0, c1, w.y);
        front = lerp(front, c2, w.z);
        front = lerp(front, c3, w.w);
        return lerp(c4, front / coverage, coverage);
    }

    public static LandscapeAlbedo sample(D3Interpolants i)
    {
        LandscapeAlbedo a;
        float4 weights = texAlpha.Sample(texAlpha_s, i.texcoord3().zw);
        float4 c0 = texLayer0.Sample(texLayer0_s, i.texcoord1().xy);
        float4 c1 = texLayer1.Sample(texLayer1_s, i.texcoord1().zw);
        float4 c2 = texLayer2.Sample(texLayer2_s, i.texcoord2().xy);
        float4 c3 = texLayer3.Sample(texLayer3_s, i.texcoord2().zw);
        float4 c4 = texLayer4.Sample(texLayer4_s, i.texcoord3().xy);
        a.weights = weights * float4(c0.w, c1.w, c2.w, c3.w);
        a.coverage = 1.0 - (1.0 - a.weights.w) * ((1.0 - a.weights.x) * (1.0 - a.weights.y) * (1.0 - a.weights.z));
        a.color = float4(over(c0.rgb, c1.rgb, c2.rgb, c3.rgb, c4.rgb, a.weights, a.coverage), 1.0);
        a.overlay = 0.0;
        return a;
    }
    public static float3 tangentNormal(D3Interpolants i, LandscapeAlbedo a)
    {
        return over(landscapeDecodeNormal(texNormal0.Sample(texNormal0_s, i.texcoord1().xy)),
                    landscapeDecodeNormal(texNormal1.Sample(texNormal1_s, i.texcoord1().zw)),
                    landscapeDecodeNormal(texNormal2.Sample(texNormal2_s, i.texcoord2().xy)),
                    landscapeDecodeNormal(texNormal3.Sample(texNormal3_s, i.texcoord2().zw)),
                    landscapeDecodeNormal(texNormal4.Sample(texNormal4_s, i.texcoord3().xy)),
                    a.weights, a.coverage);
    }
    public static float3 shade(LandscapeAlbedo a, float3 lighting) { return lighting * a.color.rgb; }
};

/// Two layers: layer0 is lit, layer1 is emissive and faded in over the lit
/// result by texAlpha.x. Layer1 doubles as the second normal map.
public struct LayerEmissivePair : ILandscapeLayers
{
    public static LandscapeAlbedo sample(D3Interpolants i)
    {
        LandscapeAlbedo a;
        a.color = texLayer0.Sample(texLayer0_s, i.texcoord1().xy);
        a.weights = texAlpha.Sample(texAlpha_s, i.texcoord3().zw);
        a.overlay = texLayer1.Sample(texLayer1_s, i.texcoord1().zw);
        a.coverage = 1.0;
        return a;
    }
    public static float3 tangentNormal(D3Interpolants i, LandscapeAlbedo a)
    {
        float3 n0 = landscapeDecodeNormal(texNormal0.Sample(texNormal0_s, i.texcoord1().xy));
        float3 n1 = landscapeDecodeNormal(a.overlay);
        return lerp(n0, n1, a.weights.x);
    }
    public static float3 shade(LandscapeAlbedo a, float3 lighting)
    {
        return lerp(lighting * a.color.rgb, a.overlay.rgb, a.weights.x);
    }
};

// ---------------------------------------------------------------------------
// Root
// ---------------------------------------------------------------------------

[shader("fragment")]
public float4 landscape_ps_main<TLayers : ILandscapeLayers, TLight : ILandscapeLight, TShadow : ILandscapeShadow,
                                TOcclusion : ILandscapeOcclusion, TGloss : ILandscapeGloss, TAlpha : IAlphaTest>(
    D3Interpolants i) : SV_Target
{
    LandscapeAlbedo albedo = TLayers.sample(i);
    LandscapeLit light = TLight.evaluate(i, TLayers.tangentNormal(i, albedo));
    TAlpha.apply(light.alpha);

    LandscapeTerms terms = landscapeTerms<TShadow, TOcclusion>(i, light, i.texcoord4(), i.texcoord6().xy);
    float3 gloss = albedo.color.a * light.specular;
    float3 color = TGloss.reflect(i, TLayers.shade(albedo, terms.lighting), gloss, terms.visibility);

    float fog = TLight.fog(i);
    float3 rgb = dbgReg0.x * d3ApplyFog(color, fog) + light.debug * dbgReg0.y;
    return float4(TGloss.debug(rgb, gloss), TLight.fogAlpha(light.alpha, fog));
}
