// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Water pixel shaders: transparent layered terrain water (Landscape.fx), ground
// puddles (Puddle.fx) and the refractive water surfaces of Reflection.fx
// (large scene water, planar-reflected water, rivers).
//
// The root is generic over the water model, which produces the final colour and
// coverage, and over the alpha test applied to that coverage.

implementing d3_shaders;

public interface IWaterPixelModel
{
    static float4 shade(D3Interpolants i);
}

/// The strength of a ripple height gradient against the flat surface: 64/255.
static const float kWaterRippleDepth = 0.250980407;

/// The surface normal perturbation of a height field at `uv`, from central
/// differences along the two offset vectors in waterTextureConstants (.xy and
/// .wz): unnormalised (dx, dy, kWaterRippleDepth).
float3 waterRippleGradient(Texture2D heights, SamplerState heights_s, float2 uv)
{
    float2 offsetX = waterTextureConstants.xy;
    float2 offsetY = waterTextureConstants.wz;
    float dx = heights.Sample(heights_s, uv + offsetX).x - heights.Sample(heights_s, uv - offsetX).x;
    float dy = heights.Sample(heights_s, uv + offsetY).x - heights.Sample(heights_s, uv - offsetY).x;
    return float3(dx, dy, kWaterRippleDepth);
}

// ---------------------------------------------------------------------------
// Layered terrain water
// ---------------------------------------------------------------------------

/// Four tiling colour layers composited by their coverage (texAlpha weight
/// times layer alpha) and normalised by the total coverage, which is also the
/// output alpha; lit and shadowed as terrain, with the light map's own
/// occlusion only.
public struct WaterLayered<TLight : ILandscapeLight, TShadow : ILandscapeShadow, TGloss : ILandscapeGloss>
    : IWaterPixelModel
{
    static float3 over(float3 c0, float3 c1, float3 c2, float3 c3, float4 w)
    {
        float3 c = lerp(c0 * w.x, c1, w.y);
        c = lerp(c, c2, w.z);
        return lerp(c, c3, w.w);
    }

    public static float4 shade(D3Interpolants i)
    {
        float4 mask = texAlpha.Sample(texAlpha_s, i.texcoord3().xy);
        float4 c0 = texLayer0.Sample(texLayer0_s, i.texcoord1().xy);
        float4 c1 = texLayer1.Sample(texLayer1_s, i.texcoord1().zw);
        float4 c2 = texLayer2.Sample(texLayer2_s, i.texcoord2().xy);
        float4 c3 = texLayer3.Sample(texLayer3_s, i.texcoord2().zw);
        float4 w = mask * float4(c0.w, c1.w, c2.w, c3.w);
        float coverage = 1.0 - (1.0 - w.x) * (1.0 - w.y) * (1.0 - w.z) * (1.0 - w.w);
        float3 surface = over(c0.xyz, c1.xyz, c2.xyz, c3.xyz, w) / coverage;

        float3 tangentNormal = over(landscapeDecodeNormal(texNormal0.Sample(texNormal0_s, i.texcoord1().xy)),
                                    landscapeDecodeNormal(texNormal1.Sample(texNormal1_s, i.texcoord1().zw)),
                                    landscapeDecodeNormal(texNormal2.Sample(texNormal2_s, i.texcoord2().xy)),
                                    landscapeDecodeNormal(texNormal3.Sample(texNormal3_s, i.texcoord2().zw)),
                                    w) / coverage;
        LandscapeLit light = TLight.evaluate(i, tangentNormal);
        LandscapeTerms terms = landscapeTerms<TShadow, OcclusionBaked>(i, light, i.texcoord4(), i.texcoord6().xy);

        float3 gloss = coverage * light.specular;
        float3 color = TGloss.reflect(i, terms.lighting * surface, gloss, terms.visibility);
        float3 rgb = dbgReg0.x * d3ApplyFog(color, TLight.fog(i)) + light.debug * dbgReg0.y;
        return float4(TGloss.debug(rgb, gloss), coverage);
    }
};

// ---------------------------------------------------------------------------
// Puddles
// ---------------------------------------------------------------------------

/// A reflective puddle: diffuse lit by the vertex light (COLOR0 at half scale)
/// with a light-map-modulated accent (TEXCOORD2), shadowed toward TEXCOORD1;
/// plus an environment reflection (TEXCOORD5, projective) perturbed by the
/// gradient of an animated water height map (TEXCOORD7) and masked by the gloss
/// map, and a gloss tint (TEXCOORD0). Fog in COLOR1.
public struct PuddleReflective<TShadow : ILandscapeShadow> : IWaterPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 lightMap = lightMapSampler.Sample(lightMapSampler_s, i.texcoord4().xy);
        float visibility = landscapeBakedTerm(lightMap.w, ShadowColor.z);
        float occlusion = landscapeBakedTerm(lightMap.x, ShadowColor.w);

        float3 accent = i.texcoord2().xyz;
        float3 light = TShadow.fade(i.texcoord1().xyz, i.color0().xyz * 2.0 - accent, i.texcoord6());
        light = visibility * accent + light;

        float4 diffuse = diffuseSampler.Sample(diffuseSampler_s, i.texcoord3().xy);
        float4 lit = float4(occlusion * light, i.color0().w) * diffuse;

        float3 ripple = normalize(waterRippleGradient(waterSampler, waterSampler_s, i.texcoord7().xy));
        float4 projected = i.texcoord5();
        float2 envUv = (ripple.xy * projected.w * 0.08 + projected.xy) / projected.w;
        float3 env = environmentMapSampler.Sample(environmentMapSampler_s, envUv).xyz;

        float3 gloss = glossMapSampler.Sample(glossMapSampler_s, i.texcoord3().xy).xyz;
        float3 color = (light * gloss) * env + ((gloss * i.texcoord0().xyz) * visibility + lit.xyz);
        // the vertex stage writes COLOR1 as a scalar: the fog factor
        return float4(d3ApplyFog(color, i.color1().x), lit.w);
    }
};

// ---------------------------------------------------------------------------
// Refractive water
// ---------------------------------------------------------------------------

/// A screen-space uv mapped into the viewport sub-rect of the current target
/// (viewport = scale u, offset u, scale v, offset v) and clamped inside it; the
/// far edge is clamped first.
float2 waterViewportUv(float2 uv)
{
    float2 far = viewport.yw + viewport.xz - 0.00001;
    return max(min(uv * viewport.xz + viewport.yw, far), viewport.yw);
}

/// What the refractive surface computed before its reflection.
public struct WaterSurface
{
    /// the perturbed surface normal
    public float3 normal;
    /// the projected screen position (TEXCOORD3 / w)
    public float3 screen;
    /// the water tint: COLOR1 to COLOR0 by the light map's alpha
    public float3 tint;
    public float fog;
};

/// The reflected colour of a refractive water surface.
public interface IWaterReflection
{
    static float3 reflection(D3Interpolants i, WaterSurface s);
}

/// The environment map, perturbed by the normal (TEXCOORD1), tinted and fogged.
public struct WaterReflectEnvironment : IWaterReflection
{
    public static float3 reflection(D3Interpolants i, WaterSurface s)
    {
        float3 env = texEnvMap.Sample(texEnvMap_s, s.normal.xy * -0.38 + i.texcoord1().xy + 0.5).xyz;
        return d3ApplyFog(env * s.tint, s.fog);
    }
};

/// Two planar reflection targets, each fading out within four units of its
/// plane (TEXCOORD7 is the world position), tinted and scaled to 0.6 under the
/// environment reflection.
public struct WaterReflectPlanar : IWaterReflection
{
    static float planeWeight(float3 position, float4 plane)
    {
        return 1.0 - min(abs(dot(float4(position, 1.0), plane) * 0.25), 1.0);
    }

    public static float3 reflection(D3Interpolants i, WaterSurface s)
    {
        float2 uv = s.screen.xy + s.normal.xy * 0.12;
        float3 near = texReflection.Sample(texReflection_s, uv).xyz;
        float3 far = texReflection1.Sample(texReflection1_s, uv).xyz;
        float3 position = i.texcoord7().xyz;
        float3 planar = near * planeWeight(position, vecReflectionPlane[0])
                      + far * planeWeight(position, vecReflectionPlane[1]);
        planar *= saturate(s.tint);
        return planar * 0.6 + WaterReflectEnvironment.reflection(i, s);
    }
};

/// How much of the reflection shows, from 1 - max(N.V, 0).
public interface IWaterFresnel
{
    static float weight(float grazing);
}

/// pow(g, 20) * 0.8 + 0.2: mostly transparent, a hard grazing reflection.
public struct FresnelSharp : IWaterFresnel
{
    public static float weight(float grazing) { return pow(grazing, 20.0) * 0.8 + 0.2; }
};

/// g^5 * 0.5 + 0.5: reflective across the whole surface.
public struct FresnelBroad : IWaterFresnel
{
    public static float weight(float grazing) { return (grazing * grazing) * (grazing * grazing) * grazing * 0.5 + 0.5; }
};

/// g^5 * 0.8 + 0.2.
public struct FresnelSchlick : IWaterFresnel
{
    public static float weight(float grazing) { return (grazing * grazing) * (grazing * grazing) * grazing * 0.8 + 0.2; }
};

/// g^2 * 0.9 + 0.1.
public struct FresnelSoft : IWaterFresnel
{
    public static float weight(float grazing) { return (grazing * grazing) * 0.9 + 0.1; }
};

/// A refractive water surface. The normal is two scrolling normal maps
/// (TEXCOORD2.xy, .wz) plus the ripple gradient (TEXCOORD0.zw); it offsets a
/// screen-space refraction that falls back to the undistorted sample where the
/// distorted texel is in front of the water or on the far plane. A murk layer
/// (TEXCOORD5) tints and fogs over the refraction by its opacity times
/// COLOR0.a, FOAM lays the whitewater texture (TEXCOORD6.xy, masked at
/// TEXCOORD0.xy) over that, and the reflection is blended in by the Fresnel
/// weight. HIGHLIGHTS adds the specular of the light rig reflected off the
/// surface (TEXCOORD7 is the view-space position).
public struct WaterRefractive<TReflection : IWaterReflection, TFresnel : IWaterFresnel,
                             let FOAM : bool, let HIGHLIGHTS : bool> : IWaterPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        WaterSurface s;
        float3 bump = texNormalMap.Sample(texNormalMap_s, i.texcoord2().xy).xyz * 2.0 - 1.0;
        bump += texNormalMap2.Sample(texNormalMap2_s, i.texcoord2().wz).xyz * 2.0 - 1.0;
        s.normal = normalize(bump + normalize(waterRippleGradient(texRipple, texRipple_s, i.texcoord0().zw)));

        s.screen = i.texcoord3().xyz / i.texcoord3().w;
        float2 straight = float2(s.screen.x, 1.0 - s.screen.y);
        float2 distorted = s.normal.xy * 0.12 + straight;
        float sceneDepth = texDepth.Sample(texDepth_s, waterViewportUv(distorted)).x;
        bool behind = (s.screen.z < sceneDepth) && (sceneDepth < 0.984375);
        float3 color = texRefraction.Sample(texRefraction_s, waterViewportUv(behind ? distorted : straight)).xyz;

        s.fog = i.texcoord4().w;
        s.tint = lerp(i.color1().xyz, i.color0().xyz, texLightmap.Sample(texLightmap_s, i.texcoord6().zw).w);
        float4 murk = texMurk.Sample(texMurk_s, s.normal.xy * 0.12 + i.texcoord5().xy);
        color = lerp(color, d3ApplyFog(s.tint * murk.xyz, s.fog), murk.w * i.color0().w);
        if (FOAM)
        {
            float4 foam = texWhitewater.Sample(texWhitewater_s, i.texcoord6().xy);
            float mask = texWhitewaterMask.Sample(texWhitewaterMask_s, i.texcoord0().xy).x;
            color = lerp(color, d3ApplyFog(s.tint * foam.xyz, s.fog), foam.w * mask);
        }

        float grazing = 1.0 - max(dot(normalize(i.texcoord4().xyz), s.normal), 0.0);
        color = lerp(color, TReflection.reflection(i, s), TFresnel.weight(grazing));
        if (HIGHLIGHTS)
        {
            float3 viewNormal = normalize(float3(dot(matWorldView[0].xyz, s.normal), dot(matWorldView[1].xyz, s.normal),
                                                 dot(matWorldView[2].xyz, s.normal)));
            color += landscapeLightRig(i.texcoord7().xyz, viewNormal, false).specular;
        }
        return float4(color, i.color0().w);
    }
};

[shader("fragment")]
public float4 water_ps_main<TModel : IWaterPixelModel, TAlpha : IAlphaTest>(D3Interpolants i) : SV_Target
{
    float4 color = TModel.shade(i);
    TAlpha.apply(color.a);
    return color;
}
