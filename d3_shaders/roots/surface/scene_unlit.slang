// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// The unlit scene surfaces: glow overlays and fades, the multi-layer glow
// floors, the unlit gloss reflection, the legacy v11 lightmap / cloud / terrain
// programs, and the engine's single-channel debug views. None of them reads the
// light rig or a shadow map.

implementing d3_shaders;

// ---------------------------------------------------------------------------
// glow
// ---------------------------------------------------------------------------

/// The glow overlay (Scene.fx ps_scene_glow): the glow map (TEXCOORD0) scaled by
/// appearanceFX.x, alpha included. NIGHT fades it out by the day time
/// (`1 - Time.z`) and fogs it.
public struct GlowOverlay<let NIGHT : bool> : ISurfacePixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 glow = glowSampler.Sample(glowSampler_s, i.texcoord0().xy) * appearanceFX.x;
        if (NIGHT)
        {
            float night = 1.0 - Time.z;
            return float4(d3ApplyFog(glow.rgb * night, i.fog().x), glow.a * night);
        }
        return glow;
    }
};

/// The fading glow surface (Scene.fx ps_scene_opaque_glow_fade): the diffuse map
/// (TEXCOORD0) lit by twice the vertex colour plus the glow map at the same
/// coordinate scaled by appearanceFX.x, fogged; the diffuse alpha is faded by
/// Factor.w.
public struct GlowFadeComposite : ISurfacePixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 diffuse = diffuseSampler.Sample(diffuseSampler_s, i.texcoord0().xy);
        float3 glow = glowSampler.Sample(glowSampler_s, i.texcoord0().xy).rgb * appearanceFX.x;
        float3 color = (i.color0().rgb * 2.0) * diffuse.rgb + glow;
        return float4(d3ApplyFog(color, i.fog().x), diffuse.a * Factor.w);
    }
};

/// The four-layer glow floor: the diffuse map (TEXCOORD0) lit by twice the
/// vertex colour, plus four glow layers (TEXCOORD1-4) summed, masked by the
/// diffuse alpha and scaled by appearanceFX.x; fogged. The coverage is the
/// alpha map (TEXCOORD0) times the diffuse alpha.
public struct GlowLayersComposite : ISurfacePixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 diffuse = diffuseSampler.Sample(diffuseSampler_s, i.texcoord0().xy);
        float coverage = alphaSampler.Sample(alphaSampler_s, i.texcoord0().xy).a * diffuse.a;
        float3 glow = glowSampler0.Sample(glowSampler0_s, i.texcoord1().xy).rgb
                    + glowSampler1.Sample(glowSampler1_s, i.texcoord2().xy).rgb
                    + glowSampler2.Sample(glowSampler2_s, i.texcoord3().xy).rgb
                    + glowSampler3.Sample(glowSampler3_s, i.texcoord4().xy).rgb;
        float3 color = (i.color0().rgb * 2.0) * diffuse.rgb + (glow * diffuse.a) * appearanceFX.x;
        return float4(d3ApplyFog(color, i.fog().x), coverage);
    }
};

/// The glowing windows' fade pass: the fogged diffuse map (TEXCOORD0) at the
/// uniform coverage Factor.w.
public struct FadeDiffuse : ISurfacePixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float3 diffuse = diffuseSampler.Sample(diffuseSampler_s, i.texcoord0().xy).rgb;
        return float4(d3ApplyFog(diffuse, i.fog().x), Factor.w);
    }
};

/// The glowing windows' silhouette pass: black under the fog, covering by the
/// diffuse alpha (TEXCOORD0) times appearanceFX.x times Factor.w.
public struct FadeSilhouette : ISurfacePixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float alpha = diffuseSampler.Sample(diffuseSampler_s, i.texcoord0().xy).a * appearanceFX.x;
        return float4(d3ApplyFog(float3(0.0, 0.0, 0.0), i.fog().x), alpha * Factor.w);
    }
};

// ---------------------------------------------------------------------------
// unlit gloss
// ---------------------------------------------------------------------------

/// The unlit multiplied gloss: a projective environment map (TEXCOORD4) masked
/// by the gloss map and the diffuse alpha (both at TEXCOORD2), fogged; the
/// diffuse map's green channel is the coverage.
public struct GlossUnlitReflection : ISurfacePixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 projected = i.texcoord4();
        float3 environment = environmentMapSampler.Sample(environmentMapSampler_s, projected.xy / projected.w).rgb;
        float3 gloss = glossMapSampler.Sample(glossMapSampler_s, i.texcoord2().xy).rgb;
        float4 diffuse = diffuseSampler.Sample(diffuseSampler_s, i.texcoord2().xy);
        return float4(d3ApplyFog((environment * gloss) * diffuse.a, i.fog().x), diffuse.g);
    }
};

// ---------------------------------------------------------------------------
// legacy v11 programs
// ---------------------------------------------------------------------------

/// The v11 glowing lightmapped surface: the diffuse map (TEXCOORD0) lit by the
/// lightmap (TEXCOORD1) plus the vertex colour, and the glow map (TEXCOORD2)
/// scaled by appearanceFX.x and by its alpha times the vertex alpha; fogged,
/// opaque.
public struct LegacyGlowLightmap : ISurfacePixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 glow = texGlow.Sample(texGlow_s, i.texcoord2().xy);
        float3 glowColor = (glow.rgb * appearanceFX.x) * (glow.a * i.color0().a);
        float3 light = texLightmap.Sample(texLightmap_s, i.texcoord1().xy).rgb + i.color0().rgb;
        float3 diffuse = texDiffuse.Sample(texDiffuse_s, i.texcoord0().xy).rgb;
        return float4(d3ApplyFog(diffuse * light + glowColor, i.fog().x), 1.0);
    }
};

/// The v11 cloud shadow: two doubled, saturated products of scrolling cloud
/// layers (tex0 x tex1 at TEXCOORD0/1, tex2 x tex3 at TEXCOORD2/3), the second
/// minus the first, tinted by Factor.rgb; opaque.
public struct LegacyCloudDifference : ISurfacePixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float3 upper = tex2.Sample(tex2_s, i.texcoord2().xy).rgb * tex3.Sample(tex3_s, i.texcoord3().xy).rgb;
        float3 lower = tex0.Sample(tex0_s, i.texcoord0().xy).rgb * tex1.Sample(tex1_s, i.texcoord1().xy).rgb;
        return float4((saturate(upper * 2.0) - saturate(lower * 2.0)) * Factor.rgb, 1.0);
    }
};

/// The v11 three-layer terrain: layer 1 (TEXCOORD1) over layer 0 (TEXCOORD0)
/// by the alpha map's green channel, layer 2 (TEXCOORD2) over that by its blue
/// channel (alpha map at TEXCOORD3); unlit, opaque.
public struct LegacyTerrainLayers : ISurfacePixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float3 layer2 = texLayer2.Sample(texLayer2_s, i.texcoord2().xy).rgb;
        float3 layer1 = texLayer1.Sample(texLayer1_s, i.texcoord1().xy).rgb;
        float3 layer0 = texLayer0.Sample(texLayer0_s, i.texcoord0().xy).rgb;
        float4 weights = texAlpha.Sample(texAlpha_s, i.texcoord3().xy);
        return float4(lerp(lerp(layer0, layer1, weights.g), layer2, weights.b), 1.0);
    }
};

// ---------------------------------------------------------------------------
// debug views
// ---------------------------------------------------------------------------

/// One quantity a scene debug view shows.
public interface ISceneDebugChannel
{
    static float3 color(D3Interpolants i);
}

/// The projective environment map (TEXCOORD4).
public struct DebugEnvironment : ISceneDebugChannel
{
    public static float3 color(D3Interpolants i)
    {
        float4 projected = i.texcoord4();
        return environmentMapSampler.Sample(environmentMapSampler_s, projected.xy / projected.w).rgb;
    }
};

/// The raw lightmap (TEXCOORD3).
public struct DebugLightmap : ISceneDebugChannel
{
    public static float3 color(D3Interpolants i)
    {
        return lightMapSampler.Sample(lightMapSampler_s, i.texcoord3().xy).rgb;
    }
};

/// The lightmap's baked sun band (TEXCOORD3), grey.
public struct DebugSunBand : ISceneDebugChannel
{
    public static float3 color(D3Interpolants i)
    {
        float band = landscapeBakedTerm(lightMapSampler.Sample(lightMapSampler_s, i.texcoord3().xy).w, ShadowColor.z);
        return float3(band, band, band);
    }
};

/// The gloss map (TEXCOORD6) through the dbgReg0 channel weights.
public struct DebugGloss : ISceneDebugChannel
{
    public static float3 color(D3Interpolants i)
    {
        return glossMapSampler.Sample(glossMapSampler_s, i.texcoord6().xy).rgb * dbgReg0.rgb;
    }
};

/// An opaque debug view of one channel.
public struct SceneDebugView<TChannel : ISceneDebugChannel> : ISurfacePixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        return float4(TChannel.color(i), 1.0);
    }
};
