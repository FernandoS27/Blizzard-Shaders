// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// The shader-model-3 scene surface without a lightmap (sm3_scene_opaque_2):
// lit per pixel through a normal map by the shared surface light rig, glossy
// through a sphere-mapped environment.

implementing d3_shaders;

/// Per-pixel lit, sphere-map gloss. One coordinate (TEXCOORD0) addresses the
/// diffuse, normal and gloss maps. The vertex stage packs the tangent frame as
/// three rows (TEXCOORD1-3 .xyz), which the decoded normal (`rgb * 2 - 1`) is
/// dotted with and NOT renormalized, and the view position in their .w. The
/// sun shadow (TEXCOORD5) blends the light from the ambient to the brighter of
/// the lit colour and the directional sun term; the environment is looked up at
/// the reflected view ray's xy remapped to [0, 1], scaled by the gloss map and
/// the rig's specular. Coverage: diffuse alpha times the vertex alpha.
public struct SphereGlossPixelComposite<TShadow : ILandscapeShadow> : ISurfacePixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float2 uv = i.texcoord0().xy;
        float3 tangent = normalSampler.Sample(normalSampler_s, uv).xyz * 2.0 - 1.0;
        float4 row0 = i.texcoord1();
        float4 row1 = i.texcoord2();
        float4 row2 = i.texcoord3();
        float3 normal = float3(dot(row0.xyz, tangent), dot(row1.xyz, tangent), dot(row2.xyz, tangent));
        float3 position = float3(row0.w, row1.w, row2.w);

        D3SurfaceLighting rig = SurfaceLightRig<false, true>.evaluate(position, normal);
        float3 lit = rig.ambient + rig.diffuse;
        float visibility = min(TShadow.visibility(i.texcoord5()), 1.0);
        float3 light = lerp(rig.ambient, max(rig.sunDiffuse, lit), visibility);

        float4 diffuse = diffuseSampler.Sample(diffuseSampler_s, uv);
        float3 gloss = glossMapSampler.Sample(glossMapSampler_s, uv).rgb;
        float3 reflected = normalize(reflect(position, normal));
        float3 environment = environmentMapSampler.Sample(environmentMapSampler_s, reflected.xy * 0.5 + 0.5).rgb;
        return float4(light * diffuse.rgb + environment * (gloss * rig.specular), diffuse.a * i.color0().a);
    }
};
