// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Fixed pixel programs of legacy-layout materials with no effect entry point
// (plan M7 residue): the DirectX 8-era `_v11` surface fallbacks (bump, lightmap,
// reflection), the UI and cutscene utilities (text outline, item icons, inactive
// sprites, video decode) and the debug views (flat shading, depth complexity,
// batch counts).
//
// Each is one fixed computation named by its pixel model; the root applies the
// measured alpha test to what the model writes.

implementing d3_shaders;

// The engine target declares the cube as a cube array (types/textures.slang):
// its coordinate gains slice 0.
#ifdef D3_TARGET_FLAKES
#define D3_CUBE_COORD(direction) float4(direction, 0.0)
#else
#define D3_CUBE_COORD(direction) direction
#endif

public interface ILegacyFixedModel
{
    static float4 shade(D3Interpolants i);
}

/// Rec. 601 luma weights as the legacy passes spell them.
static const float3 kLegacyLuma = float3(0.222, 0.707, 0.071);

// ---------------------------------------------------------------------------
// Debug views
// ---------------------------------------------------------------------------

/// Untextured flat grey.
public struct DebugFlatGrey : ILegacyFixedModel
{
    public static float4 shade(D3Interpolants i) { return float4(0.45, 0.45, 0.45, 1.0); }
};

/// One sixteenth of white per layer, summed by additive blending into an
/// overdraw count.
public struct DepthComplexityStep : ILegacyFixedModel
{
    public static float4 shade(D3Interpolants i) { return float4(0.0625, 0.0625, 0.0625, 1.0); }
};

/// The colour ramp texel of the draw's batch count (a 16-texel ramp).
public struct BatchCountRamp : ILegacyFixedModel
{
    public static float4 shade(D3Interpolants i)
    {
        float2 uv = float2(numBatches.x * 0.0625 + 0.03125, 0.5);
        return sampler0.Sample(sampler0_s, uv);
    }
};

// ---------------------------------------------------------------------------
// UI and cutscene utilities
// ---------------------------------------------------------------------------

/// A greyed-out sprite: the tinted sprite's luma, scaled down to 0.7 (or 0.2
/// when DIMMED), keeping its alpha.
public struct InactiveGreyscale<let DIMMED : bool> : ILegacyFixedModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 tinted = sampler0.Sample(sampler0_s, i.texcoord0().xy) * i.color0();
        float luma = dot(tinted.rgb, kLegacyLuma);
        float grey = luma * (DIMMED ? 0.2 : 0.7);
        return float4(grey, grey, grey, tinted.a);
    }
};

/// The diffuse luma written to red only (a single-channel recolour mask).
public struct LumaToRed : ILegacyFixedModel
{
    public static float4 shade(D3Interpolants i)
    {
        float luma = dot(texDiffuse.Sample(texDiffuse_s, i.texcoord0().xy).rgb, kLegacyLuma);
        return float4(luma, 0.0, 0.0, 1.0);
    }
};

/// Two scrolled ripple layers' red channels summed into a height, in red.
public struct RippleHeight : ILegacyFixedModel
{
    public static float4 shade(D3Interpolants i)
    {
        float a = texDiffuse0.Sample(texDiffuse0_s, i.texcoord0().xy).x;
        float b = texDiffuse1.Sample(texDiffuse1_s, i.texcoord1().xy).x;
        return float4((a + b) * 0.3, 0.0, 0.0, 1.0);
    }
};

/// Glyph outline: the glyph coverage of a 3x3 tap ring (diagonals at 0.707)
/// around the texel, averaged over three, in the vertex colour.
public struct TextOutline : ILegacyFixedModel
{
    static float tap(float2 uv, float2 offset)
    {
        return texDiffuse.Sample(texDiffuse_s, Constant0.xy * offset + uv).w;
    }

    public static float4 shade(D3Interpolants i)
    {
        float2 uv = i.texcoord0().xy;
        float sum = tap(uv, float2(-0.707, -0.707)) + tap(uv, float2(0.0, -1.0));
        sum = sum + tap(uv, float2(0.707, -0.707));
        sum = tap(uv, float2(-1.0, 0.0)) + sum;
        sum = sum + texDiffuse.Sample(texDiffuse_s, uv).w;
        sum = sum + tap(uv, float2(1.0, 0.0));
        sum = tap(uv, float2(-0.707, 0.707)) + sum;
        sum = sum + tap(uv, float2(0.0, 1.0));
        sum = tap(uv, float2(0.707, 0.707)) + sum;
        float4 tint = i.color0();
        return float4(tint.rgb, (sum * tint.w) * 0.333333343);
    }
};

/// Video frame decode: BT.601 studio-range YCbCr (Y in .z, Cr in .x, Cb in .y)
/// to RGB, written swapped to BGR, the matte from the alpha mask's red, all
/// faded by vertex alpha. The channels are assigned red first with signed
/// coefficients: fxc then shares the scaled luma the way the retail program
/// does, and which products it fuses into the sums is the float32 order.
public struct CutsceneYCbCr : ILegacyFixedModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 ycc = texDiffuse.Sample(texDiffuse_s, i.texcoord0().xy);
        float matte = texAlphaMask.Sample(texAlphaMask_s, i.texcoord1().xy).x;
        float luma = 1.164383530 * (ycc.z - 0.0627451017);
        float cb = ycc.y - 0.501960814;
        float cr = ycc.x - 0.501960814;
        float3 rgb;
        rgb.r = luma + 1.596026780 * cr;
        rgb.g = luma + -0.391762286 * cb + -0.812967658 * cr;
        rgb.b = luma + 2.017232180 * cb;
        return float4(rgb.bgr, matte) * i.color0().w;
    }
};

/// An inventory icon: the diffuse tinted by the vertex colour where the mask's
/// red is set, untinted elsewhere.
public struct IconMaskTint : ILegacyFixedModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 icon = texDiffuse.Sample(texDiffuse_s, i.texcoord0().xy);
        float mask = texMask.Sample(texMask_s, i.texcoord1().xy).x;
        return float4(lerp(icon.rgb, icon.rgb * i.color0().rgb, mask), icon.a);
    }
};

/// A morphing mesh fading into its vertex colour: the diffuse pulled towards
/// the vertex colour by the vertex colour itself, fogged; alpha modulated.
public struct VertexColorPull : ILegacyFixedModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 diffuse = diffuseSampler.Sample(diffuseSampler_s, i.texcoord0().xy);
        float4 tint = i.color0();
        float3 rgb = lerp(diffuse.rgb, tint.rgb, tint.rgb);
        return float4(d3ApplyFog(rgb, i.fog().x), diffuse.a * tint.a);
    }
};

// ---------------------------------------------------------------------------
// DirectX 8-era surface fallbacks
// ---------------------------------------------------------------------------

/// A tangent-space normal map texel decoded to [-1, 1].
float3 d3V11Normal(float4 texel) { return texel.xyz * 2.0 - 1.0; }

/// Unlit gloss surface: a projected environment map through the gloss map,
/// masked by the diffuse alpha, fogged; alpha from the diffuse green.
public struct GlossEnvironmentUnlit : ILegacyFixedModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 proj = i.texcoord4();
        float3 env = environmentMapSampler.Sample(environmentMapSampler_s, proj.xy / proj.w).rgb;
        float2 uv = i.texcoord2().xy;
        float3 gloss = glossMapSampler.Sample(glossMapSampler_s, uv).rgb;
        float4 diffuse = diffuseSampler.Sample(diffuseSampler_s, uv);
        return float4(d3ApplyFog((env * gloss) * diffuse.w, i.fog().x), diffuse.y);
    }
};

/// Lightmapped bump: N.L of the normal map against the interpolated light
/// vector lights colLight on top of the lightmap and vertex colour.
public struct BumpLightmapV11 : ILegacyFixedModel
{
    public static float4 shade(D3Interpolants i)
    {
        float3 n = d3V11Normal(texNormalMap.Sample(texNormalMap_s, i.texcoord1().xy));
        float3 l = i.texcoord3().xyz * 2.0 - 1.0;
        float nl = max(dot(n, l), 0.0);
        float3 ambient = texLightMap.Sample(texLightMap_s, i.texcoord2().xy).rgb + i.color0().rgb;
        float3 light = saturate(colLight.xyz * nl + ambient);
        return float4(light * texDiffuse.Sample(texDiffuse_s, i.texcoord0().xy).rgb, 1.0);
    }
};

/// Vertex-lit bump with gloss: N.L lights colLight over the vertex colour, an
/// (N.H)^8 highlight through the gloss map, both only facing the light and
/// scaled by the light's attenuation in TEXCOORD3.w.
public struct BumpSpecularV11 : ILegacyFixedModel
{
    public static float4 shade(D3Interpolants i)
    {
        float3 n = d3V11Normal(texNormalMap.Sample(texNormalMap_s, i.texcoord1().xy));
        float4 lightVec = i.texcoord3();
        float nl = dot(n, lightVec.xyz);
        float nh = dot(n, i.texcoord2().xyz);
        float nh2 = nh * nh;
        float nh4 = nh2 * nh2;
        float nh8 = nh4 * nh4;
        float spec = (nl >= 0.0 && nh >= 0.0) ? nh8 : 0.0;
        float2 terms = float2(max(nl, 0.0), spec) * lightVec.w;
        float3 highlight = terms.y * texGloss.Sample(texGloss_s, i.texcoord0().xy).rgb;
        float3 light = saturate(colLight.xyz * terms.x + i.color0().rgb);
        return float4(texDiffuse.Sample(texDiffuse_s, i.texcoord0().xy).rgb * light + highlight, 1.0);
    }
};

/// Irradiance bump: the irradiance cube looked up along the normal map in
/// world space (TEXCOORD2..4 rows), over the diffuse blended with its overlay,
/// tinted by Factor and the hit flash, lit twice by the vertex colour.
public struct IrradianceBumpV11 : ILegacyFixedModel
{
    public static float4 shade(D3Interpolants i)
    {
        float2 uv = i.texcoord0().xy;
        float3 n = d3V11Normal(normalMap.Sample(normalMap_s, uv));
        float3 world = float3(dot(i.texcoord2().xyz, n), dot(i.texcoord3().xyz, n), dot(i.texcoord4().xyz, n));
        float3 irradiance = irradianceMap.Sample(irradianceMap_s, D3_CUBE_COORD(world)).rgb;
        float4 overlay = diffuseOverlayMap.Sample(diffuseOverlayMap_s, i.texcoord1().xy);
        float4 diffuse = diffuseMap.Sample(diffuseMap_s, uv);
        float3 albedo = lerp(diffuse.rgb, overlay.rgb, overlay.a * diffuseOverlay.x) * Factor.xyz;
        float3 lit = (irradiance * albedo) * hitFlashColorMul.xyz;
        lit = lit * 2.0 + hitFlashColorAdd.xyz;
        lit = lit * (i.color0().rgb * Factor.xyz);
        return float4(lit + lit, (diffuse.a * i.color0().w) * Factor.w);
    }
};

/// Lightmap with ambient occlusion and animated noise: the lightmap doubled,
/// plus the vertex colour by the ambient map's blue, plus a noise texel (picked
/// by time and the ambient green) by the ambient red, over the diffuse.
public struct LightmapAmbientNoise : ILegacyFixedModel
{
    public static float4 shade(D3Interpolants i)
    {
        float2 lmuv = i.texcoord1().xy;
        float4 ambient = ambientMapSampler.Sample(ambientMapSampler_s, lmuv);
        float3 noise = noiseMapSampler.Sample(noiseMapSampler_s, float2(Time.y, ambient.y)).rgb;
        float3 lightmap = lightMapSampler.Sample(lightMapSampler_s, lmuv).rgb;
        float4 tint = i.color0();
        float3 light = noise * ambient.x + (tint.rgb * ambient.z + (lightmap + lightmap));
        float4 diffuse = diffuseSampler.Sample(diffuseSampler_s, i.texcoord0().xy);
        return float4(light * diffuse.rgb, (diffuse.a * tint.w) * Factor.w);
    }
};

/// Reflective floor: the diffuse blended towards the reflection by the Fresnel
/// map's red, fogged; opacity raised to one by the same weight.
public struct ReflectionFresnelFloor : ILegacyFixedModel
{
    public static float4 shade(D3Interpolants i)
    {
        float fresnel = texFresnel.Sample(texFresnel_s, i.texcoord2().xy).x;
        float3 reflection = texReflection.Sample(texReflection_s, i.texcoord0().xy).rgb;
        float4 diffuse = texDiffuse.Sample(texDiffuse_s, i.texcoord1().xy);
        float3 rgb = lerp(diffuse.rgb, reflection, fresnel);
        return float4(d3ApplyFog(rgb, i.fog().x), lerp(diffuse.a, 1.0, fresnel));
    }
};

/// Reflection under a decal: the projected reflection covered by the diffuse
/// by its alpha, fogged, opaque.
public struct ReflectionUnderDiffuse : ILegacyFixedModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 proj = i.texcoord0();
        float3 reflection = texReflection.Sample(texReflection_s, proj.xy / proj.w).rgb;
        float4 diffuse = texDiffuse.Sample(texDiffuse_s, i.texcoord1().xy);
        return float4(d3ApplyFog(lerp(reflection, diffuse.rgb, diffuse.a), i.fog().x), 1.0);
    }
};

[shader("fragment")]
public float4 legacy_fixed_ps_main<TModel : ILegacyFixedModel, TAlpha : IAlphaTest>(D3Interpolants i) : SV_Target
{
    float4 color = TModel.shade(i);
    TAlpha.apply(color.a);
    return color;
}
