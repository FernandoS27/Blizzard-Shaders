// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// ActorIrrad.fx pixel shading models for the actor root.
//
// The irradiance actors light their albedo against a prefiltered irradiance
// cube (the `irradianceMap` TextureCube) sampled along a normal: either the
// interpolated irradiance-space normal, or a normal-mapped one rotated through
// the interpolated world tangent frame. The vertex stage supplies the rest of
// the light, halved, which the pixel stage doubles back.

implementing d3_shaders;

// ---------------------------------------------------------------------------
// Shared pieces
// ---------------------------------------------------------------------------

/// The diffuse albedo blended toward the overlay map by its alpha, scaled by
/// `diffuseOverlay.x`.
public float3 d3OverlayAlbedo(float4 diffuse, float4 overlay)
{
    return lerp(diffuse.xyz, overlay.xyz, overlay.w * diffuseOverlay.x);
}

/// The hit-flash rim: `pow(1 - facing, hitFlashColorAdd.w)`.
public float d3HitFlashRim(float facing)
{
    return pow(1.0 - facing, hitFlashColorAdd.w);
}

/// A tangent-space normal-map texel decoded to [-1, 1].
public float3 d3DecodeNormalTexel(float4 texel)
{
    return texel.xyz * 2.0 - 1.0;
}

/// A tangent-space direction through the world tangent frame the vertex stage
/// packs one row per interpolant into TEXCOORD2..4.
public float3 d3TangentToWorld(D3Interpolants i, float3 tangentSpace)
{
    return float3(dot(i.texcoord2().xyz, tangentSpace), dot(i.texcoord3().xyz, tangentSpace),
                  dot(i.texcoord4().xyz, tangentSpace));
}

/// The sphere-map coordinate of the eye direction reflected about a normal.
public float2 d3SphereReflectionUv(float3 eye, float3 normal)
{
    float2 reflection = eye.xy - (2.0 * dot(eye, normal)) * normal.xy;
    return 0.5 - 0.5 * reflection;
}

/// A soft edge: `smoothstep(0, 1, t)` of an already saturated `t`.
public float d3SmoothEdge(float t)
{
    return t * t * (3.0 - 2.0 * t);
}

/// What the output alpha does with the coverage.
public interface IPixelCoverage
{
    static float4 finish(float3 color, float coverage);
}

/// The coverage as it is.
public struct CoverageAsIs : IPixelCoverage
{
    public static float4 finish(float3 color, float coverage) { return float4(color, coverage); }
};

/// The coverage quantised to quarter steps around 0.5: a hard cut-out mask.
public struct CoverageBanded : IPixelCoverage
{
    public static float4 finish(float3 color, float coverage)
    {
        return float4(color, saturate(ceil((coverage - 0.5) * 12.0) * 0.25));
    }
};

/// Premultiplied alpha: the saturated coverage scales the colour and leaves
/// inverted, as the transmittance.
public struct CoveragePremultiplied : IPixelCoverage
{
    public static float4 finish(float3 color, float coverage)
    {
        float opacity = saturate(coverage);
        return float4(color * opacity, 1.0 - opacity);
    }
};

// ---------------------------------------------------------------------------
// Split-light irradiance (`pvdo`)
// ---------------------------------------------------------------------------

public interface IActorAlbedo
{
    static float3 albedo(float2 uv, float4 diffuse, float4 overlay);
}

/// The diffuse map under its overlay.
public struct AlbedoOverlay : IActorAlbedo
{
    public static float3 albedo(float2 uv, float4 diffuse, float4 overlay)
    {
        return d3OverlayAlbedo(diffuse, overlay);
    }
};

/// Player dye: when `bUseDyeType` is set, a dye mask (x: ramp position,
/// z: strength) recolours the diffuse from the tint ramp before the overlay.
public struct AlbedoHeroTint : IActorAlbedo
{
    public static float3 albedo(float2 uv, float4 diffuse, float4 overlay)
    {
        if (bUseDyeType.x != 0.0)
        {
            float4 dye = heroTintMap.Sample(heroTintMap_s, uv);
            float4 ramp = tintRampMap.Sample(tintRampMap_s, float2(dye.x, tintRampUV.x));
            float4 tinted = float4(lerp(diffuse.xyz, ramp.xyz, dye.z), diffuse.w);
            return d3OverlayAlbedo(tinted, overlay);
        }
        return d3OverlayAlbedo(diffuse, overlay);
    }
};

/// How the material colour `Factor` tints the albedo and scales the coverage.
public interface IMaterialFactor
{
    static float3 tint(float4 diffuse);
    static float coverage(float4 diffuse, float vertexAlpha);
}

/// Factor.rgb over the whole surface; coverage is diffuse alpha times vertex
/// alpha times Factor.w.
public struct FactorUniform : IMaterialFactor
{
    public static float3 tint(float4 diffuse) { return Factor.xyz; }
    public static float coverage(float4 diffuse, float vertexAlpha) { return diffuse.w * vertexAlpha * Factor.w; }
};

/// Factor.rgb only where the diffuse alpha marks it; the diffuse alpha is a
/// tint mask, so coverage is vertex alpha times Factor.w.
public struct FactorAlphaMasked : IMaterialFactor
{
    public static float3 tint(float4 diffuse) { return lerp(float3(1.0, 1.0, 1.0), Factor.xyz, diffuse.w); }
    public static float coverage(float4 diffuse, float vertexAlpha) { return vertexAlpha * Factor.w; }
};

/// ActorIrrad `pvdo`: albedo times the vertex light relit by the irradiance
/// cube (`2 * COLOR0 + 4 * COLOR1 * irradiance`), the hit flash, then the
/// optional glow (into the light), gloss reflection (after the flash) and fog.
public struct IrradianceSplitPixel<TAlbedo : IActorAlbedo, TFactor : IMaterialFactor, TCoverage : IPixelCoverage,
                                   let GLOW : bool, let GLOSS : bool, let FOG : bool> : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float2 uv = i.texcoord0().xy;
        float4 diffuse = diffuseMap.Sample(diffuseMap_s, uv);
        float4 overlay = diffuseOverlayMap.Sample(diffuseOverlayMap_s, i.texcoord1().xy);
        float3 albedo = TAlbedo.albedo(uv, diffuse, overlay) * TFactor.tint(diffuse);

        float3 irradiance = irradianceMap.Sample(irradianceMap_s, i.texcoord3().xyz).xyz;
        float3 light = (i.color1().xyz * 2.0) * irradiance * 2.0 + i.color0().xyz * 2.0;
        if (GLOW)
            light += glowMap.Sample(glowMap_s, uv).xyz * appearanceFX.x;

        float3 color = light * albedo;
        color = color * hitFlashColorMul.xyz + d3HitFlashRim(i.texcoord4().z) * hitFlashColorAdd.xyz;
        if (GLOSS)
        {
            float3 specular = glossMap.Sample(glossMap_s, uv).xyz
                            * environmentMap.Sample(environmentMap_s, i.texcoord6().xy).xyz;
            color += specular * (i.texcoord7().xyz + 0.5);
        }
        if (FOG)
            color = d3ApplyFog(color, i.fog().x);
        return TCoverage.finish(color, TFactor.coverage(diffuse, i.color0().w));
    }
};

/// The selection highlight: a flat Factor.rgb shaped by the coverage.
public struct HighlightPixel<TCoverage : IPixelCoverage> : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 diffuse = diffuseMap.Sample(diffuseMap_s, i.texcoord0().xy);
        return TCoverage.finish(Factor.xyz, FactorUniform.coverage(diffuse, i.color0().w));
    }
};

/// The coverage prepass: black, carrying only the coverage.
public struct IrradiancePrepassPixel<TCoverage : IPixelCoverage> : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 diffuse = diffuseMap.Sample(diffuseMap_s, i.texcoord0().xy);
        return TCoverage.finish(float3(0.0, 0.0, 0.0), FactorUniform.coverage(diffuse, i.color0().w));
    }
};

/// The ghost depth prepass: white, diffuse alpha faded by `appearanceFX.x`.
public struct GhostPrepassPixel : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 diffuse = diffuseMap.Sample(diffuseMap_s, i.texcoord0().xy);
        return float4(1.0, 1.0, 1.0, diffuse.w * appearanceFX.x);
    }
};

// ---------------------------------------------------------------------------
// Vertex-tinted irradiance (`pv`, animated, the deaths)
// ---------------------------------------------------------------------------

/// The shared tail: tint by vertex colour times Factor, double, fog.
public float3 d3VertexTintedFog(float3 color, D3Interpolants i)
{
    color = color * (i.color0().xyz * Factor.xyz);
    return d3ApplyFog(color * 2.0, i.fog().x);
}

/// The irradiance-lit diffuse at the engine's 2x scale.
public float3 d3IrradianceDiffuse(float4 diffuse, D3Interpolants i)
{
    return diffuse.xyz * irradianceMap.Sample(irradianceMap_s, i.texcoord3().xyz).xyz * 2.0;
}

/// ActorIrrad `pv`: the irradiance-lit diffuse tinted by the vertex colour.
public struct IrradianceTintedPixel : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 diffuse = diffuseMap.Sample(diffuseMap_s, i.texcoord0().xy);
        float alpha = FactorUniform.coverage(diffuse, i.color0().w);
        return float4(d3VertexTintedFog(d3IrradianceDiffuse(diffuse, i), i), alpha);
    }
};

/// ActorIrrad animated: the irradiance-lit diffuse plus a gloss reflection
/// (weighted by COLOR1) and a scrolling layer gated by a mask map.
public struct AnimatedLayerPixel : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float2 uv = i.texcoord0().xy;
        float4 diffuse = diffuseMap.Sample(diffuseMap_s, uv);
        float alpha = FactorUniform.coverage(diffuse, i.color0().w);

        float3 color = d3IrradianceDiffuse(diffuse, i);
        float3 specular = environmentMap.Sample(environmentMap_s, i.texcoord6().xy).xyz
                        * glossMap.Sample(glossMap_s, uv).xyz;
        color += specular * (i.color1().xyz + 0.5);
        float3 layer = texAnimated.Sample(texAnimated_s, i.texcoord1().xy).xyz * texMask.Sample(texMask_s, uv).xyz;
        color += layer * 2.0;
        return float4(d3VertexTintedFog(color, i), alpha);
    }
};

/// Disintegrate death: a smooth dissolve front around (0, 1) in the TEXCOORD2
/// dissolve coordinate; where it is partial, a red burn from two burn layers,
/// elsewhere the irradiance-lit diffuse.
public struct DisintegratePixel : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float3 dissolve = i.texcoord2().xyz;
        float front = min(length(float2(dissolve.x, dissolve.y - 1.0)), 1.0);
        float edge = d3SmoothEdge(saturate((front - dissolve.z) * 10.0));

        float4 diffuse = diffuseMap.Sample(diffuseMap_s, i.texcoord0().xy);
        float4 burn = layer1DiffuseMap.Sample(layer1DiffuseMap_s, i.texcoord1().xy);
        float4 burn2 = layer2DiffuseMap.Sample(layer2DiffuseMap_s, dissolve.xy);
        float heat = saturate(burn.w * burn2.w * 4.0);

        float4 surface = edge < 1.0 ? float4(heat * float3(1.0, 0.0, 0.0), heat * edge * diffuse.w)
                                    : float4(d3IrradianceDiffuse(diffuse, i), diffuse.w);
        float alpha = FactorUniform.coverage(surface, i.color0().w);
        return float4(d3VertexTintedFog(surface.xyz, i), alpha);
    }
};

/// Pulverize death: past a smooth front at TEXCOORD2.z the surface turns into
/// the product of two crack layers, their joint alpha boosted into a hot rim.
public struct PulverizePixel<let FOG : bool> : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float edge = d3SmoothEdge(saturate(i.texcoord2().z + 0.5));
        float4 crack1 = layer1DiffuseMap.Sample(layer1DiffuseMap_s, i.texcoord1().xy);
        float4 crack2 = layer2DiffuseMap.Sample(layer2DiffuseMap_s, i.texcoord2().xy);
        float4 diffuse = diffuseMap.Sample(diffuseMap_s, i.texcoord0().xy);
        float heat = saturate(crack1.w * crack2.w * 4.0);

        float4 surface = edge < 1.0 ? float4(heat * (crack1.xyz * crack2.xyz), heat * edge * diffuse.w)
                                    : float4(d3IrradianceDiffuse(diffuse, i), diffuse.w);
        float alpha = FactorUniform.coverage(surface, i.color0().w);
        float3 color = surface.xyz * (i.color0().xyz * Factor.xyz) * 2.0;
        if (FOG)
            color = d3ApplyFog(color, i.fog().x);
        return float4(color, alpha);
    }
};

/// Elemental death: the irradiance-lit diffuse under a burn layer, tinted,
/// hit-flash multiplied, doubled, then the hit-flash rim added and fogged.
public struct ElementalPixel : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 diffuse = diffuseMap.Sample(diffuseMap_s, i.texcoord0().xy);
        float alpha = FactorUniform.coverage(diffuse, i.color0().w);
        float4 burn = layer1DiffuseMap.Sample(layer1DiffuseMap_s, i.texcoord1().xy);
        float3 color = lerp(d3IrradianceDiffuse(diffuse, i), burn.xyz, burn.w);
        color = color * (i.color0().xyz * Factor.xyz);
        color = color * hitFlashColorMul.xyz;
        color = color * 2.0;
        color += hitFlashColorAdd.xyz * d3HitFlashRim(i.texcoord4().z);
        return float4(d3ApplyFog(color, i.fog().x), alpha);
    }
};

/// Elemental wipe death: the irradiance-lit diffuse (plus glow) under a paint
/// layer, tinted and doubled; a second layer's alpha gates the coverage.
public struct WipePixel<let GLOW : bool, let FOG : bool> : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float2 uv = i.texcoord0().xy;
        float4 diffuse = diffuseMap.Sample(diffuseMap_s, uv);
        float3 color = d3IrradianceDiffuse(diffuse, i);
        if (GLOW)
            color += glowMap.Sample(glowMap_s, uv).xyz * appearanceFX.x;
        float4 paint = layer1DiffuseMap.Sample(layer1DiffuseMap_s, i.texcoord1().xy);
        color = lerp(color, paint.xyz, paint.w);
        color = color * (i.color0().xyz * Factor.xyz) * 2.0;
        if (FOG)
            color = d3ApplyFog(color, i.fog().x);
        float4 gate = layer2DiffuseMap.Sample(layer2DiffuseMap_s, i.texcoord2().xy);
        return float4(color, FactorUniform.coverage(diffuse, i.color0().w) * gate.w);
    }
};

/// The necromancer Blood Golem: two detail layers folded into the albedo
/// through a shape mask and an overlay blend, a gloss reflection whose colour
/// the same mask drives, the split vertex light relit by the irradiance cube,
/// and the hit flash.
public struct BloodGolemPixel<let FOG : bool> : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 diffuse = diffuseMap.Sample(diffuseMap_s, i.texcoord0().xy);
        float4 overlay = diffuseOverlayMap.Sample(diffuseOverlayMap_s, i.texcoord1().xy);
        float3 base = d3OverlayAlbedo(diffuse, overlay);
        float4 gate = layer2AlphaMap.Sample(layer2AlphaMap_s, i.texcoord2().zw);
        float alpha = FactorUniform.coverage(diffuse, i.color0().w) * gate.w;

        float3 tinted = base * Factor.xyz;
        float4 layer1 = layer1DiffuseMap.Sample(layer1DiffuseMap_s, i.texcoord1().xy);
        float4 layer2 = layer2DiffuseMap.Sample(layer2DiffuseMap_s, i.texcoord2().xy);
        float4 shape = layer1AlphaMap.Sample(layer1AlphaMap_s, i.texcoord0().xy);
        float3 layers = layer1.xyz * layer2.xyz;
        float3 layerColor = (shape.xyz - layers) * 0.4 + layers;
        float layerWeight = shape.w * (layer1.w * layer2.w);

        float3 screen = 1.0 - (1.0 - layerColor) * (1.0 - (tinted - 0.5) * 2.0);
        float3 multiply = layerColor * tinted * 2.0;
        float3 blended = select(tinted > 0.5, screen, multiply);
        float3 color = lerp(lerp(tinted, layerColor, 2.0 * layerWeight), blended, 0.8 * layerWeight);

        float4 gloss = glossMap.Sample(glossMap_s, i.texcoord0().xy);
        float3 specular = lerp(gloss.xyz, color * appearanceFX.x, (2.0 * layerWeight) * appearanceFX.y)
                        * environmentMap.Sample(environmentMap_s, i.texcoord6().xy).xyz;

        float3 irradiance = irradianceMap.Sample(irradianceMap_s, i.texcoord3().xyz).xyz;
        float3 light = (i.color1().xyz * 2.0) * irradiance * 2.0 + i.color0().xyz * 2.0;
        color = color * light;
        color = color * hitFlashColorMul.xyz + d3HitFlashRim(i.texcoord4().z) * hitFlashColorAdd.xyz;
        color = specular * (i.texcoord7().xyz + 0.5) + color;
        if (FOG)
            color = d3ApplyFog(color, i.fog().x);
        return float4(color, alpha);
    }
};

// ---------------------------------------------------------------------------
// Normal-mapped irradiance (`bump_pp`, the edge glows)
// ---------------------------------------------------------------------------

/// The shadow a projected shadow map casts on the vertex light.
public interface IProjectedShadow
{
    /// COLOR0's light with the shadow applied.
    static float3 vertexLight(D3Interpolants i);
}

/// No shadow.
public struct ShadowNone : IProjectedShadow
{
    public static float3 vertexLight(D3Interpolants i) { return i.color0().xyz; }
};

/// The shadow term's common tail: floored at `ShadowColor.x`, and fully lit
/// behind the projector.
public float d3ShadowTail(float shadow, float behind)
{
    shadow = max(shadow, ShadowColor.x);
    return behind < 0.0 ? 1.0 : shadow;
}

/// A 24-bit depth packed into three channels, one tap; the projected xy is
/// divided by w twice and the test uses the divided depth.
public struct ShadowPackedDepth : IProjectedShadow
{
    public static float3 vertexLight(D3Interpolants i)
    {
        float4 proj = i.texcoord5();
        float3 ndc = proj.xyz / proj.w;
        float2 uv = ndc.xy / proj.w;
        float4 texel = shadowMap.Sample(shadowMap_s, uv);
        float depth = texel.x + texel.y * (1.0 / 256.0) + texel.z * (1.0 / 65536.0);
        float shadow = texel.w * (depth >= ndc.z ? 0.0 : -1.0) + 1.0;
        return d3ShadowTail(shadow, ndc.z) * i.color0().xyz;
    }
};

/// Four bilinear taps of (depth, occlusion, strength) and a radial fade toward
/// the shadow map's edge.
public struct ShadowSoftPcf : IProjectedShadow
{
    public static float3 vertexLight(D3Interpolants i)
    {
        float4 proj = i.texcoord5();
        float size = ShadowColor.y;
        float texelSize = 1.0 / size;
        float3 ndc = proj.xyz / proj.w;
        float2 f = frac(ndc.xy * size);
        float w00 = (1.0 - f.y) * (1.0 - f.x);
        float w10 = (1.0 - f.y) * f.x;
        float w01 = (1.0 - f.x) * f.y;
        float w11 = f.y * f.x;
        float4 c = shadowMap.Sample(shadowMap_s, ndc.xy);
        float4 r = shadowMap.Sample(shadowMap_s, float2(ndc.x + texelSize, ndc.y));
        float4 d = shadowMap.Sample(shadowMap_s, float2(ndc.x, ndc.y + texelSize));
        float4 g = shadowMap.Sample(shadowMap_s, ndc.xy + texelSize);
        float depth = c.x * w00 + r.x * w10 + d.x * w01 + g.x * w11;
        float occlusion = c.z * w00 + r.z * w10 + d.z * w01 + g.z * w11;
        float strength = c.w * w00 + r.w * w10 + d.w * w01 + g.w * w11;
        float z = ndc.z + 0.001;
        bool lit = (z < (z * (1.0 - occlusion) + depth)) || (occlusion == 0.0);
        float term = lit ? 0.0 : -occlusion;
        float fade = saturate((length(ndc.xy - 0.5) - 0.4) * 10.0);
        float edge = min(1.0 - (3.0 - 2.0 * fade) * fade * fade, strength);
        return d3ShadowTail(edge * term + 1.0, proj.z) * i.color0().xyz;
    }
};

/// One fetch of four neighbouring depths, each compared and bilinearly
/// weighted, faded by a vignette map.
public struct ShadowBilinearCompare : IProjectedShadow
{
    public static float3 vertexLight(D3Interpolants i)
    {
        float4 proj = i.texcoord5();
        float size = ShadowColor.y;
        float3 ndc = proj.xyz / proj.w;
        float z = ndc.z - 0.0002;
        float2 uv = ndc.xy - 0.5 / size;
        float4 depths = shadowMap.Sample(shadowMap_s, uv / proj.w);
        float4 passed = float4(depths >= z);
        float2 f = frac(uv * size);
        float4 weights = float4((1.0 - f.y) * f.x, (1.0 - f.x) * f.y, f.y * f.x, (1.0 - f.y) * (1.0 - f.x));
        float4 vignette = vignetteMap.Sample(vignetteMap_s, uv);
        float shadow = vignette.w * (dot(passed, weights) - 1.0) + 1.0;
        return d3ShadowTail(shadow, proj.z) * i.color0().xyz;
    }
};

/// A single depth compare, faded by a vignette map.
public struct ShadowSingleCompare : IProjectedShadow
{
    public static float3 vertexLight(D3Interpolants i)
    {
        float4 proj = i.texcoord5();
        float size = ShadowColor.y;
        float3 ndc = proj.xyz / proj.w;
        float2 uv = ndc.xy - 0.5 / size;
        float z = ndc.z - 0.0002;
        float4 vignette = vignetteMap.Sample(vignetteMap_s, uv);
        float4 depth = shadowMap.Sample(shadowMap_s, uv / proj.w);
        float shadow = vignette.w * (depth.x >= z ? 0.0 : -1.0) + 1.0;
        return d3ShadowTail(shadow, proj.z) * i.color0().xyz;
    }
};

/// The hardware comparison sampler, faded by a vignette map.
public struct ShadowHardwareCompare : IProjectedShadow
{
    public static float3 vertexLight(D3Interpolants i)
    {
        float4 proj = i.texcoord5();
        float4 vignette = vignetteMap.Sample(vignetteMap_s, proj.xy / proj.w);
        float passed = shadowMap.SampleCmpLevelZero(shadowMap_cmp, proj.xy, proj.z);
        float shadow = vignette.w * (passed - 1.0) + 1.0;
        return d3ShadowTail(shadow, proj.z) * i.color0().xyz;
    }
};

/// ActorIrrad `bump_pp`: the overlay albedo lit by the irradiance cube along
/// the normal-mapped normal, hit-flashed, plus the optional gloss reflection
/// and glow, all under the (shadowed) vertex light, doubled and fogged.
public struct IrradianceBumpPixel<TShadow : IProjectedShadow, let GLOSS : bool, let GLOW : bool> : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float2 uv = i.texcoord0().xy;
        float4 diffuse = diffuseMap.Sample(diffuseMap_s, uv);
        float alpha = FactorUniform.coverage(diffuse, i.color0().w);
        float4 overlay = diffuseOverlayMap.Sample(diffuseOverlayMap_s, i.texcoord1().xy);
        float3 albedo = d3OverlayAlbedo(diffuse, overlay) * Factor.xyz;

        float3 normal = d3TangentToWorld(i, d3DecodeNormalTexel(normalMap.Sample(normalMap_s, uv)));
        float3 irradiance = irradianceMap.Sample(irradianceMap_s, normal).xyz;
        float3 color = albedo * irradiance * hitFlashColorMul.xyz * 2.0 + hitFlashColorAdd.xyz;
        if (GLOSS)
        {
            float3 specular = environmentMap.Sample(environmentMap_s, d3SphereReflectionUv(i.texcoord6().xyz, normal)).xyz
                            * glossMap.Sample(glossMap_s, uv).xyz;
            color += specular * (i.texcoord7().xyz + 0.5);
        }
        if (GLOW)
            color += glowMap.Sample(glowMap_s, uv).xyz * appearanceFX.x;
        color = color * (TShadow.vertexLight(i) * Factor.xyz);
        return float4(d3ApplyFog(color * 2.0, i.texcoord2().w), alpha);
    }
};

/// The tangent-space normal an edge-glow surface is shaded with.
public interface ITangentNormal
{
    static float3 sample(D3Interpolants i);
}

/// One normal map on UV set 0.
public struct NormalSingleMap : ITangentNormal
{
    public static float3 sample(D3Interpolants i)
    {
        return d3DecodeNormalTexel(normalMap.Sample(normalMap_s, i.texcoord0().xy));
    }
};

/// Two normal maps on their own UVs (TEXCOORD5 and COLOR1), summed and
/// renormalized.
public struct NormalDetailPair : ITangentNormal
{
    public static float3 sample(D3Interpolants i)
    {
        float3 base = d3DecodeNormalTexel(normalMap.Sample(normalMap_s, i.texcoord5().xy));
        float3 detail = d3DecodeNormalTexel(normalMap2.Sample(normalMap2_s, i.color1().xy));
        return normalize(base + detail);
    }
};

/// What an edge-glow surface shows away from its rim.
public interface IEdgeGlowSurface
{
    static float3 color(D3Interpolants i, float3 normal, float3 reflection);
}

/// The irradiance-lit overlay albedo plus the reflection.
public struct EdgeGlowIrradiance : IEdgeGlowSurface
{
    public static float3 color(D3Interpolants i, float3 normal, float3 reflection)
    {
        float2 uv = i.texcoord0().xy;
        float4 diffuse = diffuseMap.Sample(diffuseMap_s, uv);
        float4 overlay = diffuseOverlayMap.Sample(diffuseOverlayMap_s, i.texcoord1().xy);
        float3 irradiance = irradianceMap.Sample(irradianceMap_s, normal).xyz;
        float3 lit = d3OverlayAlbedo(diffuse, overlay) * Factor.xyz * irradiance * 2.0;
        return reflection + lit;
    }
};

/// The reflection alone.
public struct EdgeGlowReflectionOnly : IEdgeGlowSurface
{
    public static float3 color(D3Interpolants i, float3 normal, float3 reflection) { return reflection; }
};

/// ActorIrrad edge glow: a Fresnel rim (`1 - pow(max(-E.N, 0), edgealphaParams.x)`)
/// fades the surface toward the glow map and, scaled by edgealphaParams.y, is
/// the coverage.
public struct EdgeGlowPixel<TNormal : ITangentNormal, TSurface : IEdgeGlowSurface> : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float2 uv = i.texcoord0().xy;
        float3 normal = d3TangentToWorld(i, TNormal.sample(i));
        float3 eye = i.texcoord6().xyz;
        float edge = 1.0 - pow(max(-dot(eye, normal), 0.0), edgealphaParams.x);

        float3 reflection = environmentMap.Sample(environmentMap_s, d3SphereReflectionUv(eye, normal)).xyz
                          * glossMap.Sample(glossMap_s, uv).xyz * (i.texcoord7().xyz + 0.5);
        float3 color = TSurface.color(i, normal, reflection);
        float3 glow = glowMap.Sample(glowMap_s, uv).xyz * appearanceFX.x;
        color = lerp(color, glow, edge);
        return float4(d3ApplyFog(color, i.texcoord2().w), edge * edgealphaParams.y);
    }
};

// ---------------------------------------------------------------------------
// banner.fx
// ---------------------------------------------------------------------------

/// A clan banner: background regions (r: ramp position, g: pattern blend,
/// b: coverage), a pattern map bending the pattern colour's ramp read, and two
/// sigil masks, every colour from rows of one tint ramp; COLOR0.x is the
/// brightness.
public struct BannerPixel : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float2 uv = i.texcoord0().xy;
        float4 background = backgroundMap.Sample(backgroundMap_s, uv);
        float alpha = background.z * Factor.w;

        float pattern = patternMap.Sample(patternMap_s, uv).x;
        float rampU = background.x * 1.1;
        float patternU = background.x * (pattern * 0.2 + 0.6);
        float3 baseColor = tintRampMap.Sample(tintRampMap_s, float2(rampU, bannerTintRampUV.x)).xyz;
        float3 patternColor = tintRampMap.Sample(tintRampMap_s, float2(patternU, bannerTintRampUV.y)).xyz;
        float3 sigilColor = tintRampMap.Sample(tintRampMap_s, float2(rampU, bannerTintRampUV.z)).xyz;

        float3 color = lerp(baseColor, patternColor, background.y);
        color = lerp(color, sigilColor, sigilMainMap.Sample(sigilMainMap_s, i.texcoord1().xy).x);
        color = lerp(color, sigilColor, sigilAccentMap.Sample(sigilAccentMap_s, i.texcoord1().xy).x);
        color = color * (2.0 * i.color0().x);
        return float4(d3ApplyFog(color, i.fog().x), alpha);
    }
};
