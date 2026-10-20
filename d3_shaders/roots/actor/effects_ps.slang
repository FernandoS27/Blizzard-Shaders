// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Actor pixel shading models for the one-off effects (plan M7 residue): the
// ghost, cloak, crystal and stone-armor skins, the health orb, the elemental
// deaths and hit-flashed layers, the necromancer revive, the tornado, the
// banner highlight and Actor.fx's glow pass. Each is an IActorPixelModel of
// roots/actor/actor_ps.slang and reuses the irradiance helpers of
// roots/actor/irradiance_ps.slang.

implementing d3_shaders;

// The engine target declares the cube as a cube array (types/textures.slang):
// its coordinate gains slice 0.
#ifdef D3_TARGET_FLAKES
#define D3_CUBE_COORD(direction) float4(direction, 0.0)
#else
#define D3_CUBE_COORD(direction) direction
#endif

// ---------------------------------------------------------------------------
// Unlit
// ---------------------------------------------------------------------------

/// banner.fx highlight: the flat Factor colour, covering where the background's
/// coverage channel meets the vertex alpha.
public struct BannerHighlightPixel : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 background = backgroundMap.Sample(backgroundMap_s, i.texcoord0().xy);
        return float4(Factor.xyz, background.z * i.color0().w);
    }
};

/// Actor.fx glow pass: the vertex-lit diffuse plus a Factor-tinted glow map,
/// clamped, then fogged; coverage is diffuse alpha times vertex alpha.
public struct ActorGlowPixel : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 diffuse = diffuseSampler.Sample(diffuseSampler_s, i.texcoord0().xy);
        float3 glow = glowSampler.Sample(glowSampler_s, i.texcoord1().xy).xyz * Factor.xyz;
        float3 color = saturate(i.color0().xyz * diffuse.xyz + glow);
        return float4(d3ApplyFog(color, i.fog().x), diffuse.w * i.color0().w);
    }
};

/// The cloak: the interpolated normal packed into [0, 1], pushed away from grey
/// by `appearanceFX.x` and faded back to grey by the coverage; opaque.
public struct CloakPixel : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 diffuse = diffuseMap.Sample(diffuseMap_s, i.texcoord0().xy);
        float coverage = FactorUniform.coverage(diffuse, i.color0().w);
        float3 packed = i.texcoord1().xyz * 0.5 + 0.5;
        float3 color = (packed * appearanceFX.x - 0.5) * coverage + 0.5;
        return float4(color, 1.0);
    }
};

// ---------------------------------------------------------------------------
// Ghosts
// ---------------------------------------------------------------------------

/// How a ghost fades the alpha it writes.
public interface IGhostFade
{
    static float fade(D3Interpolants i, float alpha);
}

/// Unfaded.
public struct GhostFadeNone : IGhostFade
{
    public static float fade(D3Interpolants i, float alpha) { return alpha; }
};

/// Eaten away by the dissipation map's alpha, read at unit UNIT.
public struct GhostFadeDissipate<let UNIT : int> : IGhostFade
{
    public static float fade(D3Interpolants i, float alpha)
    {
        return alpha * dissipationMap.Sample(dissipationMap_s, d3UnitTexcoord(i, UNIT)).w;
    }
};

/// Another fade, then two alpha masks on TEXCOORD1 and TEXCOORD2.
public struct GhostFadeMasked<TBase : IGhostFade> : IGhostFade
{
    public static float fade(D3Interpolants i, float alpha)
    {
        float masked = TBase.fade(i, alpha) * alpha1Map.Sample(alpha1Map_s, i.texcoord1().xy).w;
        return masked * alpha2Map.Sample(alpha2Map_s, i.texcoord2().xy).w;
    }
};

/// The ghost shell: where the diffuse survives `appearanceFX.x`, the ghost
/// map's alpha scaled by it, grey in every channel.
public struct GhostShellPixel<TFade : IGhostFade> : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 diffuse = diffuseMap.Sample(diffuseMap_s, i.texcoord0().xy);
        if (diffuse.w * appearanceFX.x == 0.0)
            discard;
        float ghost = ghostMap.Sample(ghostMap_s, i.texcoord0().xy).w * appearanceFX.x;
        return float4(ghost, ghost, ghost, TFade.fade(i, ghost));
    }
};

/// The irradiance-lit ghost: the coverage is alpha-tested before
/// `appearanceFX.x` fades it; the colour is the diffuse lit by the irradiance
/// cube at 4x, tinted and fogged.
public struct GhostIrradiancePixel<TTest : IAlphaTest, TFade : IGhostFade> : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 diffuse = diffuseMap.Sample(diffuseMap_s, i.texcoord0().xy);
        float coverage = FactorUniform.coverage(diffuse, i.color0().w);
        TTest.apply(coverage);
        float faded = coverage * appearanceFX.x;
        float3 irradiance = irradianceMap.Sample(irradianceMap_s, D3_CUBE_COORD(i.texcoord3().xyz)).xyz;
        float3 color = diffuse.xyz * irradiance * Factor.xyz * 4.0;
        return float4(d3ApplyFog(color, i.fog().x), TFade.fade(i, faded));
    }
};

// ---------------------------------------------------------------------------
// Vertex-tinted irradiance variants
// ---------------------------------------------------------------------------

/// Elemental character death: the irradiance-lit diffuse fading by its own
/// alpha toward the mean of two reads of the burn layer.
public struct CharredLayerPixel : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 diffuse = diffuseMap.Sample(diffuseMap_s, i.texcoord0().xy);
        float coverage = FactorUniform.coverage(diffuse, i.color0().w);
        float3 burn = layer1DiffuseMap.Sample(layer1DiffuseMap_s, i.texcoord1().xy).xyz
                    + layer1DiffuseMap.Sample(layer1DiffuseMap_s, i.texcoord2().xy).xyz;
        float3 color = lerp(d3IrradianceDiffuse(diffuse, i), burn * 0.5, diffuse.w);
        return float4(d3VertexTintedFog(color, i), coverage);
    }
};

/// Thousand Pounder: the vertex-tinted irradiance diffuse, its coverage also
/// masked by an animated map's alpha.
public struct AnimatedMaskPixel : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float mask = animatedMap.Sample(animatedMap_s, i.texcoord1().xy).w;
        float4 diffuse = diffuseMap.Sample(diffuseMap_s, i.texcoord0().xy);
        float coverage = ((mask * diffuse.w) * i.color0().w) * Factor.w;
        return float4(d3VertexTintedFog(d3IrradianceDiffuse(diffuse, i), i), coverage);
    }
};

/// Elemental (Jill) skins: the irradiance-lit diffuse under a colour layer whose
/// alpha is also the coverage (doubled), tinted, hit-flashed and fogged.
/// LAYER_2X doubles the layer colour.
public struct ElementalLayerPixel<let LAYER_2X : bool> : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 layer = layer1DiffuseMap.Sample(layer1DiffuseMap_s, i.texcoord1().xy);
        float coverage = (layer.w * i.color0().w) * Factor.w * 2.0;
        float4 diffuse = diffuseMap.Sample(diffuseMap_s, i.texcoord0().xy);
        float3 lit = d3IrradianceDiffuse(diffuse, i);
        float3 paint = LAYER_2X ? layer.xyz * 2.0 : layer.xyz;
        float3 color = lerp(lit, paint, layer.w) * (i.color0().xyz * Factor.xyz);
        color = color * hitFlashColorMul.xyz * 2.0;
        color = color + hitFlashColorAdd.xyz * d3HitFlashRim(i.texcoord4().z);
        return float4(d3ApplyFog(color, i.fog().x), coverage);
    }
};

/// The whirlwind: three layers' joint alpha, boosted and clamped, is the
/// coverage; the colour is the irradiance-lit diffuse at 4x, read along the
/// TEXCOORD4 normal, optionally fogged.
public struct TornadoPixel<let FOG : bool> : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float swirl = layer1DiffuseMap.Sample(layer1DiffuseMap_s, i.texcoord1().xy).w
                    * layer2DiffuseMap.Sample(layer2DiffuseMap_s, i.texcoord2().xy).w
                    * layer3DiffuseMap.Sample(layer3DiffuseMap_s, i.texcoord3().xy).w;
        float mask = saturate(swirl * Factor.w * 4.0);
        float coverage = mask * i.color0().w * Factor.w;
        float4 diffuse = diffuseMap.Sample(diffuseMap_s, i.texcoord0().xy);
        float3 irradiance = irradianceMap.Sample(irradianceMap_s, D3_CUBE_COORD(i.texcoord4().xyz)).xyz;
        float3 color = diffuse.xyz * irradiance * Factor.xyz * 4.0;
        if (FOG)
            color = d3ApplyFog(color, i.fog().x);
        return float4(color, coverage);
    }
};

// ---------------------------------------------------------------------------
// Split-light irradiance variants
// ---------------------------------------------------------------------------

/// The split vertex light relit by the irradiance cube (`pvdo`).
public float3 d3SplitIrradianceLight(D3Interpolants i)
{
    float3 irradiance = irradianceMap.Sample(irradianceMap_s, D3_CUBE_COORD(i.texcoord3().xyz)).xyz;
    return (i.color1().xyz * 2.0) * irradiance * 2.0 + i.color0().xyz * 2.0;
}

/// The sphere-mapped gloss reflection weighted by the interpolated specular.
public float3 d3GlossReflection(D3Interpolants i, float2 envUv, float3 specular)
{
    float3 reflection = glossMap.Sample(glossMap_s, i.texcoord0().xy).xyz
                      * environmentMap.Sample(environmentMap_s, envUv).xyz;
    return reflection * (specular + 0.5);
}

/// Necromancer pet revive: the overlay albedo's red channel, scaled by
/// `Factor.x`, looks the colour up in a ramp row (TEXCOORD2.y); a second
/// overlay's alpha gates the coverage. Lit by the split light, hit-flashed,
/// glossed and fogged.
public struct ReviveRampPixel : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 gate = diffuseOverlay2Map.Sample(diffuseOverlay2Map_s, i.texcoord2().zw);
        float4 diffuse = diffuseMap.Sample(diffuseMap_s, i.texcoord0().xy);
        float coverage = gate.w * FactorUniform.coverage(diffuse, i.color0().w);
        float4 overlay = diffuseOverlayMap.Sample(diffuseOverlayMap_s, i.texcoord1().xy);
        float rampU = d3OverlayAlbedo(diffuse, overlay).x * Factor.x;
        float3 albedo = diffuse1Map.Sample(diffuse1Map_s, float2(rampU, i.texcoord2().y)).xyz;
        float3 color = albedo * d3SplitIrradianceLight(i);
        color = color * hitFlashColorMul.xyz + d3HitFlashRim(i.texcoord4().z) * hitFlashColorAdd.xyz;
        color = d3GlossReflection(i, i.texcoord6().xy, i.texcoord7().xyz) + color;
        return float4(d3ApplyFog(color, i.fog().x), coverage);
    }
};

/// The health orb: the overlay albedo lit by the irradiance cube alone (no
/// vertex light), hit-flashed, glossed and fogged.
public struct HealthOrbPixel : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 overlay = diffuseOverlayMap.Sample(diffuseOverlayMap_s, i.texcoord1().xy);
        float4 diffuse = diffuseMap.Sample(diffuseMap_s, i.texcoord0().xy);
        float3 albedo = d3OverlayAlbedo(diffuse, overlay);
        float coverage = FactorUniform.coverage(diffuse, i.color0().w);
        float3 irradiance = irradianceMap.Sample(irradianceMap_s, D3_CUBE_COORD(i.texcoord3().xyz)).xyz;
        float3 color = albedo * Factor.xyz * irradiance * hitFlashColorMul.xyz * 2.0;
        color = hitFlashColorAdd.xyz * d3HitFlashRim(i.texcoord4().z) + color;
        color = d3GlossReflection(i, i.texcoord6().xy, i.texcoord7().xyz) + color;
        return float4(d3ApplyFog(color, i.fog().x), coverage);
    }
};

/// Morlu: the split-lit overlay albedo whose light also gains a glow map
/// tinted by a second overlay (on TEXCOORD7.xy), plus the gloss reflection
/// (sphere map on TEXCOORD5, specular on TEXCOORD6); fog rides in TEXCOORD7.z.
public struct GlowOverlayPixel : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float2 uv = i.texcoord0().xy;
        float4 diffuse = diffuseMap.Sample(diffuseMap_s, uv);
        float coverage = FactorUniform.coverage(diffuse, i.color0().w);
        float4 overlay = diffuseOverlayMap.Sample(diffuseOverlayMap_s, i.texcoord1().xy);
        float3 albedo = d3OverlayAlbedo(diffuse, overlay) * Factor.xyz;
        float3 light = d3SplitIrradianceLight(i);
        float3 glow = glowMap.Sample(glowMap_s, uv).xyz * appearanceFX.x;
        light = glow * diffuseOverlay1Map.Sample(diffuseOverlay1Map_s, i.texcoord7().xy).xyz + light;
        float3 color = albedo * light + d3GlossReflection(i, i.texcoord5().xy, i.texcoord6().xyz);
        return float4(d3ApplyFog(color, i.texcoord7().z), coverage);
    }
};

// ---------------------------------------------------------------------------
// Fresnel-blended skins (the crystal vertex stage's layout)
// ---------------------------------------------------------------------------

/// The gloss reflection of the crystal layout: sphere map on TEXCOORD5,
/// specular in COLOR1.
public float3 d3CrystalReflection(D3Interpolants i)
{
    float3 reflection = environmentMap.Sample(environmentMap_s, i.texcoord5().xy).xyz
                      * glossMap.Sample(glossMap_s, i.texcoord0().xy).xyz;
    return reflection * (i.color1().xyz + 0.5);
}

/// Stone armor: the irradiance-lit diffuse blends toward a stone map by the
/// view normal's |z| (TEXCOORD1.z) and gains the reflection by z squared; opaque.
public struct StoneSkinPixel : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float2 uv = i.texcoord0().xy;
        float3 lit = diffuseMap.Sample(diffuseMap_s, uv).xyz
                   * irradianceMap.Sample(irradianceMap_s, D3_CUBE_COORD(i.texcoord3().xyz)).xyz;
        float3 stone = diffuse2Map.Sample(diffuse2Map_s, uv).xyz;
        float facing = i.texcoord1().z;
        float3 color = lerp(lit * 2.0, stone, abs(facing));
        color = d3CrystalReflection(i) * (facing * facing) + color;
        return float4(d3ApplyFog(color, i.fog().x), 1.0);
    }
};

/// Crystal: the screen behind the surface (TEXCOORD2 is the clip x, y, w),
/// refracted along the view normal and clamped to the viewport, shows plain
/// where the surface faces the viewer and tinted by the irradiance-lit diffuse
/// toward grazing angles, where the reflection comes in. Opaque.
public struct CrystalPixel : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float3 normal = i.texcoord1().xyz;
        float3 clip = i.texcoord2().xyz;
        float2 screen = (clip.xy / clip.z) * float2(0.5, -0.5) + normal.xy * 0.03 + 0.5;
        screen = screen * viewport.xz + viewport.yw;
        float2 limit = (viewport.yw + viewport.xz) - 0.00001;
        screen = max(min(limit, screen), viewport.yw);
        float3 refraction = refractionMap.Sample(refractionMap_s, screen).xyz;

        float4 diffuse = diffuseMap.Sample(diffuseMap_s, i.texcoord0().xy);
        float3 lit = diffuse.xyz * irradianceMap.Sample(irradianceMap_s, D3_CUBE_COORD(i.texcoord3().xyz)).xyz;
        lit = lit + lit;
        float3 color = lerp(refraction * lit, refraction, normal.z * normal.z);
        color = (1.0 - normal.z * normal.z) * d3CrystalReflection(i) + color;
        return float4(d3ApplyFog(color, i.fog().x), 1.0);
    }
};
