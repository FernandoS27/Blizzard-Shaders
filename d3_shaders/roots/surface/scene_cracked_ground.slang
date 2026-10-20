// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// The cracked-sand ground (the scene_transparent_ground_sand_crack materials):
// a transparent decal whose sand layer covers a crack layer, both lit by the
// lightmapped scene light (scene_models.slang) and composited over the ground
// beneath with premultiplied "over" coverage.

implementing d3_shaders;

/// The two normal maps of the "_pp" cracked ground, tapped at the sand layer's
/// coordinate (TEXCOORD4) and blended by the sand coverage: the sand map's
/// alpha at the crack coordinate (TEXCOORD3) times the vertex coverage the
/// per-pixel vertex stage packs in TEXCOORD10.w.
public struct NormalFromCoveredLayers : ISceneNormal
{
    public static float3 offset(D3Interpolants i)
    {
        float cover = diffuseSandSampler.Sample(diffuseSandSampler_s, i.texcoord3().xy).a * i.texcoord10().w;
        float3 lower = landscapeDecodeNormal(normalMapSampler0.Sample(normalMapSampler0_s, i.texcoord4().xy));
        float3 upper = landscapeDecodeNormal(normalMapSampler1.Sample(normalMapSampler1_s, i.texcoord4().xy));
        return lerp(lower, upper, cover) + float3(0.0, 0.0, -1.0);
    }
};

/// Sand over cracks. The sand map's alpha at the crack coordinate (TEXCOORD3),
/// times the vertex coverage, is how much sand lies on top; its colour comes
/// from its own coordinate (TEXCOORD4). The crack layer (TEXCOORD3) shows
/// through the rest with its own alpha. Both layers take the same shaded light
/// (lightmap at TEXCOORD2, whose .w is the fog factor; shadow at TEXCOORD5),
/// and the sum is un-premultiplied by the combined coverage
/// `1 - (1 - crack.a) * (1 - sand)`, which is also what the alpha test sees.
public struct CrackedGroundComposite<TLight : ISceneLighting, TShadow : ILandscapeShadow> : ISurfacePixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 crack = diffuseCrackSampler.Sample(diffuseCrackSampler_s, i.texcoord3().xy);
        float sandCover = diffuseSandSampler.Sample(diffuseSandSampler_s, i.texcoord3().xy).a;
        float3 sand = diffuseSandSampler.Sample(diffuseSandSampler_s, i.texcoord4().xy).rgb;

        SceneLight light = TLight.evaluate(i);
        float4 lightmapCoord = i.texcoord2();
        float4 lightmap = lightMapSampler.Sample(lightMapSampler_s, lightmapCoord.xy);
        float band = min(landscapeBakedTerm(lightmap.w, ShadowColor.z), TShadow.visibility(i.texcoord5()));
        float occlusion = landscapeBakedTerm(lightmap.x, ShadowColor.w);
        float3 shaded = sceneShadedLight(light, band, occlusion);

        float cover = sandCover * light.alpha;
        float exposed = 1.0 - cover;
        float alpha = 1.0 - (1.0 - crack.a) * exposed;
        float3 color = (crack.rgb * shaded) * (exposed * crack.a) + shaded * (cover * sand);
        color = d3ApplyFog(color / alpha, lightmapCoord.w);
        return float4(dbgReg0.x * color + light.lit * dbgReg0.y, alpha);
    }
};
