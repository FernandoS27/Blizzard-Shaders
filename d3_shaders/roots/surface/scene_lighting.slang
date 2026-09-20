// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// The light a lightmapped scene surface receives, before the lightmap, shadow
// and occlusion terms pick how much of it lands.
//
// Every Scene.fx surface consumes the same five quantities:
//   lit       the fully lit colour (also the additive debug-glow source);
//   bright    the upper end of the lightmap's dark -> bright blend;
//   dark      the ambient / shadowed lower end;
//   specular  the light colour gloss and reflections are scaled by;
//   alpha     the vertex coverage.
// The vertex-lit surfaces receive them baked into interpolants; the "_pp"
// surfaces evaluate them per pixel through a normal map with the shared light
// rig (math/surface_lights.slang), the vertex colour added as emissive.

implementing d3_shaders;

public struct SceneLight
{
    public float3 lit;
    public float3 bright;
    public float3 dark;
    public float3 specular;
    public float alpha;
};

public interface ISceneLighting
{
    static SceneLight evaluate(D3Interpolants i);
}

/// Lighting baked by the vertex stage: COLOR0 carries half the lit colour and
/// the coverage, COLOR1 half the specular, TEXCOORD0/1 the dark and bright ends.
public struct VertexLighting : ISceneLighting
{
    public static SceneLight evaluate(D3Interpolants i)
    {
        SceneLight light;
        light.lit = i.color0().rgb * 2.0;
        light.bright = max(light.lit, i.texcoord1().xyz);
        light.dark = i.texcoord0().xyz;
        light.specular = i.color1().rgb * 2.0;
        light.alpha = i.color0().a;
        return light;
    }
};

// ---------------------------------------------------------------------------
// per-pixel normals
// ---------------------------------------------------------------------------

/// Where a surface's tangent-space normal comes from, as its offset from +Z
/// (the per-pixel lighting scales the offset by `normalMapScale.x`).
public interface ISceneNormal
{
    static float3 offset(D3Interpolants i);
}

/// A normal-map texel's offset from +Z, with the z part kept as `-|xy|`.
float3 sceneNormalOffset(float4 texel)
{
    float2 xy = texel.wy * 2.0 - 1.0;
    return float3(xy, -length(xy));
}

/// One normal map at the diffuse coordinate (TEXCOORD2).
public struct NormalFromNormalMap : ISceneNormal
{
    public static float3 offset(D3Interpolants i)
    {
        return sceneNormalOffset(normalMapSampler.Sample(normalMapSampler_s, i.texcoord2().xy));
    }
};

/// The floor normal map at its own coordinate (TEXCOORD3).
public struct NormalFromFloorMap : ISceneNormal
{
    public static float3 offset(D3Interpolants i)
    {
        return sceneNormalOffset(texNormalMap.Sample(texNormalMap_s, i.texcoord3().xy));
    }
};

/// One normal map tapped at both diffuse layers' coordinates (TEXCOORD3/4),
/// blended by the upper layer's alpha like the albedo.
public struct NormalFromLayers : ISceneNormal
{
    public static float3 offset(D3Interpolants i)
    {
        float blend = diffuse1Sampler.Sample(diffuse1Sampler_s, i.texcoord4().xy).a;
        float3 lower = landscapeDecodeNormal(normalMapSampler0.Sample(normalMapSampler0_s, i.texcoord3().xy));
        float3 upper = landscapeDecodeNormal(normalMapSampler0.Sample(normalMapSampler0_s, i.texcoord4().xy));
        return lerp(lower, upper, blend) + float3(0.0, 0.0, -1.0);
    }
};

/// The base normal map (TEXCOORD2) blended toward the overlay's own normal map
/// (TEXCOORD4) by the overlay amount.
public struct NormalFromOverlay : ISceneNormal
{
    public static float3 offset(D3Interpolants i)
    {
        float amount = overlayMapSampler.Sample(overlayMapSampler_s, i.texcoord4().xy).a * i.texcoord4().z;
        float3 base = landscapeDecodeNormal(normalMapSampler0.Sample(normalMapSampler0_s, i.texcoord2().xy));
        float3 overlay = landscapeDecodeNormal(normalMapSampler1.Sample(normalMapSampler1_s, i.texcoord4().xy));
        return lerp(base, overlay, amount) + float3(0.0, 0.0, -1.0);
    }
};

// ---------------------------------------------------------------------------
// per-pixel lighting
// ---------------------------------------------------------------------------

/// Per-pixel lighting through the shared CBLights rig (SPOT: the four spot
/// lights; GLOSS: Phong specular). The vertex stage packs five interpolants
/// from TEXCOORD`FRAME` on: the view position, the frame's z, x and y axes,
/// and the emissive vertex colour with the coverage in .w.
public struct PixelLighting<TNormal : ISceneNormal, let FRAME : int, let SPOT : bool, let GLOSS : bool>
    : ISceneLighting
{
    public static SceneLight evaluate(D3Interpolants i)
    {
        float3 position = sceneTexcoord(i, FRAME).xyz;
        float3 axisZ = sceneTexcoord(i, FRAME + 1).xyz;
        float3 axisX = sceneTexcoord(i, FRAME + 2).xyz;
        float3 axisY = sceneTexcoord(i, FRAME + 3).xyz;
        float4 emissive = sceneTexcoord(i, FRAME + 4);

        float3 t = normalize(normalMapScale.x * TNormal.offset(i) + float3(0.0, 0.0, 1.0));
        float3 normal = normalize(t.x * axisX + t.y * axisY + t.z * axisZ);
        D3SurfaceLighting rig = SurfaceLightRig<SPOT, GLOSS>.evaluate(position, normal);

        SceneLight light;
        light.lit = emissive.xyz * 2.0 + (rig.ambient + rig.diffuse);
        light.dark = emissive.xyz * 2.0 + rig.ambient;
        light.bright = max(rig.sunDiffuse, light.lit);
        light.specular = rig.specular;
        light.alpha = emissive.w;
        return light;
    }
};
