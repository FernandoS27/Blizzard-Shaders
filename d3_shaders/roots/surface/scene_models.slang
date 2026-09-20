// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// The lightmapped scene surfaces (Scene.fx, Prop.fx).
//
// They share the terrain's shading spine (landscape_shading.slang): the
// lightmap's .w is a baked sun band and its .x baked ambient occlusion, each
// remapped around 1 by ShadowColor.z/.w; the band is capped by the sun shadow
// (the same five kernels as the terrain), the occlusion optionally by
// screen-space AO. The band blends the received light from its dark to its
// bright end, the occlusion scales the result, and the diffuse map, gloss and
// fog follow. The engine's debug split writes
// `dbgReg0.x * colour + dbgReg0.y * lit (+ dbgReg0.z * specular)`.
//
// What differs between the surfaces is where the vertex stage put the
// coordinates and what is layered on top; each surface is one model below.

implementing d3_shaders;

/// The received light after the sun band and the occlusion.
public float3 sceneShadedLight(SceneLight light, float band, float occlusion)
{
    return occlusion * (light.dark + band * (light.bright - light.dark));
}

// ---------------------------------------------------------------------------
// Scene.fx ps_scene / ps_scene_aux
// ---------------------------------------------------------------------------

/// The general scene surface. Diffuse at TEXCOORD2, lightmap at TEXCOORD3;
/// with GLOSS a gloss map at TEXCOORD6 scales the specular, added once under
/// the lightmap band and once through a projective reflection (TEXCOORD4),
/// which pushes the shadow coordinate from TEXCOORD4 to TEXCOORD5.
public struct LightmapComposite<TLight : ISceneLighting, TShadow : ILandscapeShadow, TOcclusion : ILandscapeOcclusion,
                                TShape : IAlphaShape, let GLOSS : bool, let FOG : bool> : ISurfacePixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 lightmap = lightMapSampler.Sample(lightMapSampler_s, i.texcoord3().xy);
        float band = landscapeBakedTerm(lightmap.w, ShadowColor.z);
        float visibility = min(band, TShadow.visibility(sceneTexcoord(i, GLOSS ? 5 : 4)));
        float occlusion = landscapeBakedTerm(TOcclusion.occlusion(i, lightmap.x), ShadowColor.w);

        SceneLight light = TLight.evaluate(i);
        float4 diffuse = diffuseSampler.Sample(diffuseSampler_s, i.texcoord2().xy);
        float3 color = sceneShadedLight(light, visibility, occlusion) * diffuse.rgb;
        float alpha = TShape.shape(light.alpha * diffuse.a);

        float3 specular = float3(0.0, 0.0, 0.0);
        if (GLOSS)
        {
            specular = light.specular * glossMapSampler.Sample(glossMapSampler_s, i.texcoord6().xy).rgb;
            color += specular * band;
            float4 reflection = i.texcoord4();
            color += specular * environmentMapSampler.Sample(environmentMapSampler_s, reflection.xy / reflection.w).rgb;
        }
        if (FOG)
            color = d3ApplyFog(color, i.fog().x);

        float3 debug = dbgReg0.x * color + light.lit * dbgReg0.y;
        if (GLOSS)
            debug += dbgReg0.z * specular;
        return float4(debug, alpha);
    }
};

// ---------------------------------------------------------------------------
// Prop.fx ps_prop
// ---------------------------------------------------------------------------

/// The prop surface. The vertex stage splits its light into TEXCOORD1, the
/// part the lightmap band gates, and the rest (`2 * COLOR0 - TEXCOORD1`),
/// which the sun shadow fades toward TEXCOORD0. Gloss is sampled at the
/// diffuse coordinate; the reflection's projective coordinate (TEXCOORD4)
/// pushes the shadow coordinate to TEXCOORD5.
public struct PropComposite<TShadow : ILandscapeShadow, TShape : IAlphaShape, let GLOSS : bool, let FOG : bool>
    : ISurfacePixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 diffuse = diffuseSampler.Sample(diffuseSampler_s, i.texcoord2().xy);
        float alpha = TShape.shape(i.color0().a * diffuse.a);

        float3 banded = i.texcoord1().xyz;
        float3 direct = i.color0().rgb * 2.0 - banded;
        float3 unbanded = TShadow.fade(i.texcoord0().xyz, direct, sceneTexcoord(i, GLOSS ? 5 : 4));

        float4 lightmap = lightMapSampler.Sample(lightMapSampler_s, i.texcoord3().xy);
        float band = landscapeBakedTerm(lightmap.w, ShadowColor.z);
        float occlusion = landscapeBakedTerm(lightmap.x, ShadowColor.w);
        float3 color = ((unbanded + band * banded) * occlusion) * diffuse.rgb;

        if (GLOSS)
        {
            float3 specular = (i.color1().rgb * 2.0) * glossMapSampler.Sample(glossMapSampler_s, i.texcoord2().xy).rgb;
            color += specular * band;
            float4 reflection = i.texcoord4();
            color += specular * environmentMapSampler.Sample(environmentMapSampler_s, reflection.xy / reflection.w).rgb;
        }
        if (FOG)
            color = d3ApplyFog(color, i.fog().x);
        return float4(color, alpha);
    }
};

// ---------------------------------------------------------------------------
// Scene.fx ps_scene_battlenet
// ---------------------------------------------------------------------------

/// The unlit glowing surface: the lightmap alone lights the diffuse map, its
/// band capped by a sun shadow that darkens at most half way (TEXCOORD4), and
/// the vertex colour adds a glow. PACKED_COLOR: the "_pp" vertex stage moves
/// the vertex colour to TEXCOORD9 and biases the glow by one.
public struct LightmapGlowComposite<TShadow : ILandscapeShadow, let PACKED_COLOR : bool> : ISurfacePixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 vertex = PACKED_COLOR ? i.texcoord9() : i.color0();
        float4 diffuse = diffuseSampler.Sample(diffuseSampler_s, i.texcoord2().xy);
        float alpha = vertex.a * diffuse.a;

        float4 lightmap = lightMapSampler.Sample(lightMapSampler_s, i.texcoord3().xy);
        float band = landscapeBakedTerm(lightmap.w, ShadowColor.z);
        float gain = landscapeBakedTerm(lightmap.x, ShadowColor.w);
        float sun = TShadow.visibility(i.texcoord4()) * 0.5 + 0.5;
        float3 color = d3ApplyFog((gain * min(band, sun)) * diffuse.rgb, i.fog().x);

        float3 glow = vertex.rgb * 2.0;
        if (PACKED_COLOR)
            glow = glow + 1.0;
        return float4(dbgReg0.x * color + glow * dbgReg0.y, alpha);
    }
};

// ---------------------------------------------------------------------------
// Scene.fx ps_scene_glow_2tex
// ---------------------------------------------------------------------------

/// The two-layer floor: two diffuse layers (TEXCOORD3/4) blended by the upper
/// layer's alpha, whose complement is the coverage. Lightmap at TEXCOORD2,
/// shadow at TEXCOORD5, screen-space AO always.
public struct TwoLayerComposite<TLight : ISceneLighting, TShadow : ILandscapeShadow> : ISurfacePixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 lower = diffuseSampler.Sample(diffuseSampler_s, i.texcoord3().xy);
        float4 upper = diffuse1Sampler.Sample(diffuse1Sampler_s, i.texcoord4().xy);

        SceneLight light = TLight.evaluate(i);
        float4 lightmap = lightMapSampler.Sample(lightMapSampler_s, i.texcoord2().xy);
        float band = min(landscapeBakedTerm(lightmap.w, ShadowColor.z), TShadow.visibility(i.texcoord5()));
        float occlusion = landscapeBakedTerm(OcclusionScreenSpace.occlusion(i, lightmap.x), ShadowColor.w);

        float3 albedo = lerp(lower.rgb, upper.rgb, upper.a);
        float3 color = d3ApplyFog(sceneShadedLight(light, band, occlusion) * albedo, i.fog().x);
        return float4(dbgReg0.x * color + light.lit * dbgReg0.y, 1.0 - upper.a);
    }
};

// ---------------------------------------------------------------------------
// Scene.fx ps_scene_overlay
// ---------------------------------------------------------------------------

/// The overlay floor: the glossy scene surface with screen-space AO, whose
/// result is blended toward an overlay decal (TEXCOORD4, amount in .z times
/// the decal's alpha) lit by the same light. Lightmap and fog share
/// TEXCOORD3; reflection at TEXCOORD5, shadow at TEXCOORD6, gloss at TEXCOORD7.
public struct OverlayComposite<TLight : ISceneLighting, TShadow : ILandscapeShadow> : ISurfacePixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 overlay = overlayMapSampler.Sample(overlayMapSampler_s, i.texcoord4().xy);
        float amount = overlay.w * i.texcoord4().z;

        SceneLight light = TLight.evaluate(i);
        float4 lightmapCoord = i.texcoord3();
        float4 lightmap = lightMapSampler.Sample(lightMapSampler_s, lightmapCoord.xy);
        float band = landscapeBakedTerm(lightmap.w, ShadowColor.z);
        float visibility = min(band, TShadow.visibility(i.texcoord6()));
        float occlusion = landscapeBakedTerm(OcclusionScreenSpace.occlusion(i, lightmap.x), ShadowColor.w);
        float3 shaded = sceneShadedLight(light, visibility, occlusion);

        float4 diffuse = diffuseSampler.Sample(diffuseSampler_s, i.texcoord2().xy);
        float3 color = shaded * diffuse.rgb;
        float alpha = light.alpha * diffuse.a;

        float3 specular = light.specular * glossMapSampler.Sample(glossMapSampler_s, i.texcoord7().xy).rgb;
        color += specular * band;
        float4 reflection = i.texcoord5();
        color += specular * environmentMapSampler.Sample(environmentMapSampler_s, reflection.xy / reflection.w).rgb;

        color = lerp(color, overlay.rgb * shaded, amount);
        color = d3ApplyFog(color, lightmapCoord.w);
        float3 debug = dbgReg0.x * color + light.lit * dbgReg0.y;
        return float4(debug + dbgReg0.z * specular, alpha);
    }
};

// ---------------------------------------------------------------------------
// Scene.fx ps_scene_act4_floor
// ---------------------------------------------------------------------------

/// The Heaven floor: diffuse layers A/B blended by TEXCOORD6.x, a reflection
/// bent by the floor normal map (TEXCOORD3) around its projective coordinate
/// (TEXCOORD4), gloss scaled by 0.31 * TEXCOORD6.y. Lightmap in TEXCOORD2.xy,
/// layers and gloss at TEXCOORD2.zw, shadow at TEXCOORD5, screen-space AO
/// always.
public struct FloorReflectionComposite<TLight : ISceneLighting, TShadow : ILandscapeShadow> : ISurfacePixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        SceneLight light = TLight.evaluate(i);

        float3 tangent = landscapeDecodeNormal(texNormalMap.Sample(texNormalMap_s, i.texcoord3().xy));
        float4 reflection = i.texcoord4();
        float2 bent = normalize(tangent).xy * reflection.w * 0.12 + reflection.xy;
        float3 environment = environmentMapSampler.Sample(environmentMapSampler_s, bent / reflection.w).rgb;

        float4 coords = i.texcoord2();
        float4 lightmap = lightMapSampler.Sample(lightMapSampler_s, coords.xy);
        float band = min(landscapeBakedTerm(lightmap.w, ShadowColor.z), TShadow.visibility(i.texcoord5()));
        float occlusion = landscapeBakedTerm(OcclusionScreenSpace.occlusion(i, lightmap.x), ShadowColor.w);

        float4 layerBlend = i.texcoord6();
        float3 gloss = glossMapSampler.Sample(glossMapSampler_s, coords.zw).rgb;
        float3 specular = (light.specular + environment) * gloss * (layerBlend.y * 0.31);
        float3 layerA = diffuseSamplerA.Sample(diffuseSamplerA_s, coords.zw).rgb;
        float3 layerB = diffuseSamplerB.Sample(diffuseSamplerB_s, coords.zw).rgb;
        float3 albedo = lerp(layerB, layerA, layerBlend.x);

        float3 color = d3ApplyFog(sceneShadedLight(light, band, occlusion) * albedo + specular, i.fog().x);
        color = dbgReg0.x * color + light.lit * dbgReg0.y;
        return float4(dbgReg0.z * (light.specular * gloss) + color, light.alpha);
    }
};
