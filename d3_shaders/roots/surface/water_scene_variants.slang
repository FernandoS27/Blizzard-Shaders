// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// The scene-material variants of the refractive water of water_ps.slang
// (scene_water, scene_water_reflect, scene_opaque_floor_largewater and its
// fixed-environment twin): the same refraction, murk and Fresnel blend, with
// the bump normal, the fog and the reflection chosen per material.

implementing d3_shaders;

/// Where a refractive water surface's bump normal comes from.
public interface IWaterBumpSource
{
    static float3 normal(D3Interpolants i);
}

/// Two scrolling normal maps (TEXCOORD2.xy, .wz) plus the ripple gradient
/// (TEXCOORD0.zw), as WaterRefractive computes it.
public struct WaterBumpMapsAndRipple : IWaterBumpSource
{
    public static float3 normal(D3Interpolants i)
    {
        float3 bump = texNormalMap.Sample(texNormalMap_s, i.texcoord2().xy).xyz * 2.0 - 1.0;
        bump += texNormalMap2.Sample(texNormalMap2_s, i.texcoord2().wz).xyz * 2.0 - 1.0;
        return normalize(bump + normalize(waterRippleGradient(texRipple, texRipple_s, i.texcoord0().zw)));
    }
};

/// The ripple gradient (TEXCOORD0.zw) alone: no normal maps are bound.
public struct WaterBumpRippleOnly : IWaterBumpSource
{
    public static float3 normal(D3Interpolants i)
    {
        return normalize(waterRippleGradient(texRipple, texRipple_s, i.texcoord0().zw));
    }
};

/// Whether the tinted layers of a water surface take the scene fog.
public interface IWaterFogPolicy
{
    static float3 apply(float3 color, float fog);
}

public struct WaterFogApplied : IWaterFogPolicy
{
    public static float3 apply(float3 color, float fog) { return d3ApplyFog(color, fog); }
};

/// The material does not fog (the vertex stage packs no fog factor).
public struct WaterFogIgnored : IWaterFogPolicy
{
    public static float3 apply(float3 color, float fog) { return color; }
};

/// The environment map perturbed by the normal (TEXCOORD1), tinted, unfogged.
public struct WaterReflectEnvironmentUnfogged : IWaterReflection
{
    public static float3 reflection(D3Interpolants i, WaterSurface s)
    {
        return texEnvMap.Sample(texEnvMap_s, s.normal.xy * -0.38 + i.texcoord1().xy + 0.5).xyz * s.tint;
    }
};

/// The environment map projected from TEXCOORD1 (xy / w), its uv perturbed by
/// the normal in projected space; tinted, unfogged.
public struct WaterReflectProjectedUnfogged : IWaterReflection
{
    public static float3 reflection(D3Interpolants i, WaterSurface s)
    {
        float4 projected = i.texcoord1();
        float2 uv = (s.normal.xy * 0.12 * projected.w + projected.xy) / projected.w;
        return texEnvMap.Sample(texEnvMap_s, uv).xyz * s.tint;
    }
};

/// The two planar reflection targets of WaterReflectPlanar, each fading out
/// within four units of its plane, over the unfogged environment reflection.
public struct WaterReflectPlanarUnfogged : IWaterReflection
{
    static float planeFade(float3 position, float4 plane)
    {
        return 1.0 - min(abs(dot(float4(position, 1.0), plane) * 0.25), 1.0);
    }

    public static float3 reflection(D3Interpolants i, WaterSurface s)
    {
        float2 uv = s.screen.xy + s.normal.xy * 0.12;
        float3 near = texReflection.Sample(texReflection_s, uv).xyz;
        float3 far = texReflection1.Sample(texReflection1_s, uv).xyz;
        float3 position = i.texcoord7().xyz;
        float3 planar = near * planeFade(position, vecReflectionPlane[0])
                      + far * planeFade(position, vecReflectionPlane[1]);
        planar *= saturate(s.tint);
        return planar * 0.6 + WaterReflectEnvironmentUnfogged.reflection(i, s);
    }
};

/// g^5 * 0.7 + 0.3.
public struct FresnelMild : IWaterFresnel
{
    public static float weight(float grazing) { return (grazing * grazing) * (grazing * grazing) * grazing * 0.7 + 0.3; }
};

/// WaterRefractive without foam or highlights, over a chosen bump normal and
/// fog policy: the screen-space refraction, the murk layer (TEXCOORD5) tinted
/// over it by its opacity times COLOR0.a, and the reflection blended in by the
/// Fresnel weight of 1 - max(N.V, 0) (TEXCOORD4 is the view vector, .w the fog).
public struct WaterRefractiveVariant<TBump : IWaterBumpSource, TFog : IWaterFogPolicy, TReflection : IWaterReflection,
                                     TFresnel : IWaterFresnel> : IWaterPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        WaterSurface s;
        s.normal = TBump.normal(i);

        s.screen = i.texcoord3().xyz / i.texcoord3().w;
        float2 straight = float2(s.screen.x, 1.0 - s.screen.y);
        float2 distorted = s.normal.xy * 0.12 + straight;
        float sceneDepth = texDepth.Sample(texDepth_s, waterViewportUv(distorted)).x;
        bool behind = (s.screen.z < sceneDepth) && (sceneDepth < 0.984375);
        float3 color = texRefraction.Sample(texRefraction_s, waterViewportUv(behind ? distorted : straight)).xyz;

        s.fog = i.texcoord4().w;
        s.tint = lerp(i.color1().xyz, i.color0().xyz, texLightmap.Sample(texLightmap_s, i.texcoord6().zw).w);
        float4 murk = texMurk.Sample(texMurk_s, s.normal.xy * 0.12 + i.texcoord5().xy);
        color = lerp(color, TFog.apply(s.tint * murk.xyz, s.fog), murk.w * i.color0().w);

        float grazing = 1.0 - max(dot(normalize(i.texcoord4().xyz), s.normal), 0.0);
        color = lerp(color, TReflection.reflection(i, s), TFresnel.weight(grazing));
        return float4(color, i.color0().w);
    }
};
