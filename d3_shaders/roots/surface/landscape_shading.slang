// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Terrain shading shared by the landscape and water pixel roots (Landscape.fx,
// Puddle.fx, and the river highlights of Reflection.fx): the sun shadow
// kernels, the light-map terms, where a vertex stage packed its fog factor, and
// the per-pixel light rig.
//
// Every terrain program ends in the same shading equation. A light-map texel
// carries two baked terms, a sun visibility in .w and an ambient occlusion in
// .x, each scaled toward 1 by ShadowColor.z / ShadowColor.w. The dynamic sun
// shadow can only darken the baked visibility (`min`), and the result fades the
// light from its ambient floor to its fully lit colour; the occlusion then
// scales the whole term:
//
//     lighting = lerp(ambient, lit, min(lightMapVisibility, sunShadow)) * occlusion
//
// What varies is where `ambient` and `lit` come from -- baked into the vertex
// colours, or evaluated per pixel from normal maps and the CBLights rig -- and
// how the sun shadow is filtered.

implementing d3_shaders;

// ---------------------------------------------------------------------------
// Sun shadow kernels
// ---------------------------------------------------------------------------

/// A sun shadow filter: the visibility of a pixel from its projective shadow
/// coordinate, in [ShadowColor.x, 1], 1 where nothing occludes the sun.
public interface ILandscapeShadow
{
    static float visibility(float4 coord);
    /// `lit` faded toward `floor` by the visibility; a program without a shadow
    /// map does not blend at all.
    static float3 fade(float3 floor, float3 lit, float4 coord);
}

/// The shadow floor, and nothing is shadowed on the near side of the light.
float landscapeShadowFloor(float shadow, float depth)
{
    shadow = max(shadow, ShadowColor.x);
    return depth < 0.0 ? 1.0 : shadow;
}

/// No shadow map is bound: fully visible.
public struct LandscapeShadowNone : ILandscapeShadow
{
    public static float visibility(float4 coord) { return 1.0; }
    public static float3 fade(float3 floor, float3 lit, float4 coord) { return lit; }
};

/// One tap of a colour target packing 24-bit depth in RGB (1, 1/256, 1/65536)
/// and the shadow strength in A. The texel is fetched at the projected
/// coordinate divided by w a second time, as the engine's projection expects.
public struct LandscapeShadowPacked : ILandscapeShadow
{
    public static float visibility(float4 coord)
    {
        float3 proj = coord.xyz / coord.w;
        float4 texel = shadowMapSampler.Sample(shadowMapSampler_s, proj.xy / coord.w);
        float depth = texel.x + texel.y * (1.0 / 256.0) + texel.z * (1.0 / 65536.0);
        float occluded = depth >= proj.z ? 0.0 : -1.0;
        return landscapeShadowFloor(texel.w * occluded + 1.0, proj.z);
    }
    public static float3 fade(float3 floor, float3 lit, float4 coord) { return lerp(floor, lit, visibility(coord)); }
};

/// A soft 2x2 bilinear filter over a moments target (.x depth moment, .z
/// occluder coverage, .w strength), faded out toward the rim of the shadow
/// projection. A texel with zero coverage never shadows.
public struct LandscapeShadowSoft : ILandscapeShadow
{
    public static float visibility(float4 coord)
    {
        float3 proj = coord.xyz / coord.w;
        float2 f = frac(proj.xy * ShadowColor.y);
        float texel = 1.0 / ShadowColor.y;
        float w00 = (1.0 - f.y) * (1.0 - f.x);
        float w10 = (1.0 - f.y) * f.x;
        float w01 = (1.0 - f.x) * f.y;
        float w11 = f.y * f.x;
        float3 m00 = shadowMapSampler.Sample(shadowMapSampler_s, proj.xy).xzw;
        float3 m10 = shadowMapSampler.Sample(shadowMapSampler_s, float2(proj.x + texel, proj.y)).xzw;
        float3 m01 = shadowMapSampler.Sample(shadowMapSampler_s, float2(proj.x, proj.y + texel)).xzw;
        float3 m11 = shadowMapSampler.Sample(shadowMapSampler_s, proj.xy + texel).xzw;
        float3 moments = w10 * m10 + w00 * m00 + w01 * m01 + w11 * m11;

        float biased = proj.z + 0.001;
        bool lit = (biased < biased * (1.0 - moments.y) + moments.x) || (moments.y == 0.0);
        float occluded = lit ? 0.0 : -moments.y;
        float rim = saturate((length(proj.xy - 0.5) - 0.4) * 10.0);
        float fade = 1.0 - (3.0 - 2.0 * rim) * (rim * rim);
        return landscapeShadowFloor(min(fade, moments.z) * occluded + 1.0, coord.z);
    }
    public static float3 fade(float3 floor, float3 lit, float4 coord) { return lerp(floor, lit, visibility(coord)); }
};

/// One tap of a native depth target, biased, half a texel back; the vignette
/// texture's alpha gives the shadow strength.
public struct LandscapeShadowDepth : ILandscapeShadow
{
    public static float visibility(float4 coord)
    {
        float halfTexel = 0.5 / ShadowColor.y;
        float3 proj = coord.xyz / coord.w;
        float2 base = proj.xy - halfTexel;
        float biased = proj.z - 0.0002;
        float strength = vignetteSampler.Sample(vignetteSampler_s, base).w;
        float depth = shadowMapSampler.Sample(shadowMapSampler_s, base / coord.w).x;
        float occluded = depth >= biased ? 0.0 : -1.0;
        return landscapeShadowFloor(strength * occluded + 1.0, coord.z);
    }
    public static float3 fade(float3 floor, float3 lit, float4 coord) { return lerp(floor, lit, visibility(coord)); }
};

/// Percentage-closer filtering of one texel that stores the four depths of a
/// 2x2 neighbourhood in RGBA, bilinearly weighted; vignette strength.
public struct LandscapeShadowDepthQuad : ILandscapeShadow
{
    public static float visibility(float4 coord)
    {
        float3 proj = coord.xyz / coord.w;
        float biased = proj.z - 0.0002;
        float2 base = proj.xy - 0.5 / ShadowColor.y;
        float4 depths = shadowMapSampler.Sample(shadowMapSampler_s, base / coord.w);
        float4 passed = select(depths >= biased, float4(1.0), float4(0.0));
        float2 f = frac(base * ShadowColor.y);
        float4 weights = float4((1.0 - f.y) * f.x, (1.0 - f.x) * f.y, f.y * f.x, (1.0 - f.y) * (1.0 - f.x));
        float strength = vignetteSampler.Sample(vignetteSampler_s, base).w;
        return landscapeShadowFloor(strength * (dot(passed, weights) - 1.0) + 1.0, coord.z);
    }
    public static float3 fade(float3 floor, float3 lit, float4 coord) { return lerp(floor, lit, visibility(coord)); }
};

/// The hardware comparison sampler; vignette strength at the projected point.
public struct LandscapeShadowCompare : ILandscapeShadow
{
    public static float visibility(float4 coord)
    {
        float strength = vignetteSampler.Sample(vignetteSampler_s, coord.xy / coord.w).w;
        float passed = shadowMapSampler.SampleCmpLevelZero(shadowMapSampler_cmp, coord.xy, coord.z);
        return landscapeShadowFloor(strength * (passed - 1.0) + 1.0, coord.z);
    }
    public static float3 fade(float3 floor, float3 lit, float4 coord) { return lerp(floor, lit, visibility(coord)); }
};

// ---------------------------------------------------------------------------
// Light-map terms
// ---------------------------------------------------------------------------

/// A baked term of the light map, scaled toward 1 by its ShadowColor weight.
public float landscapeBakedTerm(float texel, float weight)
{
    return (texel - 1.0) * weight + 1.0;
}

/// Ambient occlusion: the light map's baked term, or its minimum with the
/// screen-space buffer in the passes that have one.
public interface ILandscapeOcclusion
{
    static float occlusion(D3Interpolants i, float bakedOcclusion);
}

public struct OcclusionBaked : ILandscapeOcclusion
{
    public static float occlusion(D3Interpolants i, float bakedOcclusion) { return bakedOcclusion; }
};

public struct OcclusionScreenSpace : ILandscapeOcclusion
{
    public static float occlusion(D3Interpolants i, float bakedOcclusion)
    {
        float2 screen = i.position().xy * windowResolution.xy;
        return min(bakedOcclusion, ssaoSampler.Sample(ssaoSampler_s, screen).w);
    }
};

// ---------------------------------------------------------------------------
// Fog packing
// ---------------------------------------------------------------------------

/// Where the paired vertex stage put the fog factor (1 unfogged). The vertex
/// stage packs one baked light channel next to it, so the packing also names
/// where that channel went, and whether the fog blend covers alpha.
public interface ILandscapeFog
{
    static float factor(D3Interpolants i);
    /// The first of the three baked light channels (the others are TEXCOORD0.w
    /// and TEXCOORD5.w in every packing).
    static float bakedChannel(D3Interpolants i);
    static float alpha(float alpha, float fog);
}

/// Fog in its own FOG interpolant; the baked channel in COLOR1.w.
/// BLEND_ALPHA fogs the output alpha toward fogColor.w as well.
public struct FogInterpolant<let BLEND_ALPHA : bool> : ILandscapeFog
{
    public static float factor(D3Interpolants i) { return i.fog().x; }
    public static float bakedChannel(D3Interpolants i) { return i.color1().w; }
    public static float alpha(float alpha, float fog)
    {
        if (BLEND_ALPHA)
            return lerp(fogColor.w, alpha, fog);
        return alpha;
    }
};

/// Fog in TEXCOORD5.y, the baked channel beside it in TEXCOORD5.x.
public struct FogTexcoord5 : ILandscapeFog
{
    public static float factor(D3Interpolants i) { return i.texcoord5().y; }
    public static float bakedChannel(D3Interpolants i) { return i.texcoord5().x; }
    public static float alpha(float alpha, float fog) { return alpha; }
};

/// Fog in COLOR1.w (COLOR1.xyz is the gloss colour), the baked channel in
/// COLOR0.w; alpha is fogged too.
public struct FogColor1 : ILandscapeFog
{
    public static float factor(D3Interpolants i) { return i.color1().w; }
    public static float bakedChannel(D3Interpolants i) { return i.color0().w; }
    public static float alpha(float alpha, float fog) { return lerp(fogColor.w, alpha, fog); }
};

// ---------------------------------------------------------------------------
// Lighting
// ---------------------------------------------------------------------------

/// The lighting of one pixel before the shadow and occlusion terms.
public struct LandscapeLit
{
    /// the floor a shadowed pixel falls back to
    public float3 ambient;
    /// the fully lit colour
    public float3 lit;
    /// what the dbgReg0.y debug channel shows
    public float3 debug;
    /// the gloss colour before the diffuse alpha masks it
    public float3 specular;
    public float alpha;
};

/// Where a terrain pixel's light comes from. `tangentNormal` is the blended
/// normal-map normal; vertex-lit programs ignore it.
public interface ILandscapeLight
{
    static LandscapeLit evaluate(D3Interpolants i, float3 tangentNormal);
    static float fog(D3Interpolants i);
    static float fogAlpha(float alpha, float fog);
}

/// Light baked per vertex: COLOR0.rgb at half scale, an ambient floor in
/// TEXCOORD0.xyz, three baked channels that floor the lit colour per
/// component, and the gloss colour in COLOR1.rgb at half scale.
public struct LandscapeVertexLit<TFog : ILandscapeFog> : ILandscapeLight
{
    public static LandscapeLit evaluate(D3Interpolants i, float3 tangentNormal)
    {
        LandscapeLit l;
        float3 light = i.color0().rgb * 2.0;
        float3 channels = float3(TFog.bakedChannel(i), i.texcoord0().w, i.texcoord5().w);
        l.ambient = i.texcoord0().xyz;
        l.lit = max(light, channels);
        l.debug = light;
        l.specular = i.color1().rgb * 2.0;
        l.alpha = i.color0().w;
        return l;
    }
    public static float fog(D3Interpolants i) { return TFog.factor(i); }
    public static float fogAlpha(float alpha, float fog) { return TFog.alpha(alpha, fog); }
};

/// Where the per-pixel vertex stage put the geometry: world position, the
/// tangent frame (normal, tangent, binormal) and the vertex colour, in five
/// consecutive TEXCOORDs.
public interface IPixelFrame
{
    static float3 position(D3Interpolants i);
    static float3 normal(D3Interpolants i);
    static float3 tangent(D3Interpolants i);
    static float3 binormal(D3Interpolants i);
    static float4 color(D3Interpolants i);
}

public struct PixelFrameAt7 : IPixelFrame
{
    public static float3 position(D3Interpolants i) { return i.texcoord7().xyz; }
    public static float3 normal(D3Interpolants i) { return i.texcoord8().xyz; }
    public static float3 tangent(D3Interpolants i) { return i.texcoord9().xyz; }
    public static float3 binormal(D3Interpolants i) { return i.texcoord10().xyz; }
    public static float4 color(D3Interpolants i) { return i.texcoord11(); }
};

public struct PixelFrameAt8 : IPixelFrame
{
    public static float3 position(D3Interpolants i) { return i.texcoord8().xyz; }
    public static float3 normal(D3Interpolants i) { return i.texcoord9().xyz; }
    public static float3 tangent(D3Interpolants i) { return i.texcoord10().xyz; }
    public static float3 binormal(D3Interpolants i) { return i.texcoord11().xyz; }
    public static float4 color(D3Interpolants i) { return i.texcoord12(); }
};

public struct PixelFrameAt9 : IPixelFrame
{
    public static float3 position(D3Interpolants i) { return i.texcoord9().xyz; }
    public static float3 normal(D3Interpolants i) { return i.texcoord10().xyz; }
    public static float3 tangent(D3Interpolants i) { return i.texcoord11().xyz; }
    public static float3 binormal(D3Interpolants i) { return i.texcoord12().xyz; }
    public static float4 color(D3Interpolants i) { return i.texcoord13(); }
};

/// A tangent-space normal stored DXT5nm style: x in alpha, y in green, z
/// rebuilt as 1 - |xy|.
public float3 landscapeDecodeNormal(float4 texel)
{
    float2 xy = texel.wy * 2.0 - 1.0;
    return float3(xy, 1.0 - length(xy));
}

/// Light accumulated over the CBLights rig at one pixel.
public struct LandscapeLightSum
{
    public float3 ambient;
    public float3 diffuse;
    public float3 specular;
    /// the primary light's diffuse when it is directional (wp.w = 0)
    public float3 directional;
};

/// The Phong lobe of one light for a reflected view ray.
float3 landscapeSpecular(float3 reflected, float3 toLight, float3 color)
{
    return pow(max(dot(reflected, toLight), 0.0), SpecularPower.x) * color;
}

/// The per-pixel light rig: the primary light (lightPoints[0], quadratic
/// attenuation, positional or directional by wp.w), optionally the four scene
/// spotlights, the point-linear lights (numLights.x, at most 16) and the first
/// cylindrical light. Specular is gathered from every light but the cylinder.
public LandscapeLightSum landscapeLightRig(float3 position, float3 normal, bool spotlights)
{
    LandscapeLightSum sum;
    float3 reflected = normalize(reflect(position, normal));

    float3 toLight = lightPoints[0].wp.xyz - position * lightPoints[0].wp.w;
    float dist2 = dot(toLight, toLight);
    float atten = 1.0 / (lightPoints[0].atten.y * sqrt(dist2) + lightPoints[0].atten.x
                         + dist2 * lightPoints[0].atten.z);
    toLight = toLight * rsqrt(dist2);
    float3 diffuse = atten * (max(dot(toLight, normal), 0.0) * lightPoints[0].colDiffuse.xyz);
    sum.ambient = lightPoints[0].colAmbient.xyz * atten + colAmbient.xyz;
    sum.diffuse = diffuse;
    sum.directional = (1.0 - lightPoints[0].wp.w) * diffuse;
    sum.specular = atten * landscapeSpecular(reflected, toLight, lightPoints[0].colSpecular.xyz);

    if (spotlights)
    {
        for (int k = 0; k < 4; ++k)
        {
            float3 toSpot = lightSpots[k].wp - position;
            float spot2 = dot(toSpot, toSpot);
            float reach = saturate((lightSpots[k].radii.y - sqrt(spot2)) * lightSpots[k].radii.x);
            toSpot = toSpot * rsqrt(spot2);
            float cosAngle = dot(toSpot, -lightSpots[k].wv);
            // inside the inner cone the falloff is replaced, not skipped: the
            // blend still multiplies it by zero
            float inner = cosAngle >= lightSpots[k].radii.w ? 1.0 : 0.0;
            float falloff = max((cosAngle - lightSpots[k].radii.z)
                                / (lightSpots[k].radii.w - lightSpots[k].radii.z), 0.0);
            float cone = (1.0 - inner) * falloff + inner;
            sum.ambient += (reach * lightSpots[k].colAmbient.xyz) * cone;
            sum.diffuse += (reach * (max(dot(toSpot, normal), 0.0) * lightSpots[k].colDiffuse.xyz)) * cone;
            sum.specular += landscapeSpecular(reflected, toSpot, lightSpots[k].colSpecular.xyz) * (cone * reach);
        }
    }

    int count = min(int(numLights.x), 16);
    for (int k = 0; k < count; ++k)
    {
        float3 toPoint = lightPointLinears[k].wp - position;
        float point2 = dot(toPoint, toPoint);
        float reach = saturate((lightPointLinears[k].colDiffuse_radiiB.w - sqrt(point2))
                               * lightPointLinears[k].colAmbient_radiiA.w);
        toPoint = toPoint * rsqrt(point2);
        sum.ambient += lightPointLinears[k].colAmbient_radiiA.xyz * reach;
        sum.diffuse += (max(dot(toPoint, normal), 0.0) * lightPointLinears[k].colDiffuse_radiiB.xyz) * reach;
        sum.specular += landscapeSpecular(reflected, toPoint, lightPointLinears[k].colSpecular.xyz) * reach;
    }

    float3 toAxis = lightCylindricals[0].wp - position;
    float axis2 = dot(toAxis, toAxis);
    float axial = dot(toAxis, lightCylindricals[0].wv);
    float perpendicular = sqrt(max(axis2 - axial * axial, 0.0));
    toAxis = toAxis * rsqrt(axis2);
    float reach = saturate((lightCylindricals[0].radii.y - perpendicular) * lightCylindricals[0].radii.x);
    sum.ambient += lightCylindricals[0].colAmbient.xyz * reach;
    sum.diffuse += (max(dot(toAxis, normal), 0.0) * lightCylindricals[0].colDiffuse.xyz) * reach;
    return sum;
}

/// Light evaluated per pixel: the blended normal-map normal, rescaled by
/// normalMapScale.x and rotated through the interpolated tangent frame, lit by
/// the CBLights rig and tinted by twice the vertex colour.
public struct LandscapePixelLit<TFog : ILandscapeFog, TFrame : IPixelFrame, let SPOTLIGHTS : bool> : ILandscapeLight
{
    public static LandscapeLit evaluate(D3Interpolants i, float3 tangentNormal)
    {
        float3 n = normalize(normalMapScale.x * (tangentNormal + float3(0.0, 0.0, -1.0)) + float3(0.0, 0.0, 1.0));
        float3 normal = normalize(n.x * TFrame.tangent(i) + n.y * TFrame.binormal(i) + n.z * TFrame.normal(i));
        LandscapeLightSum sum = landscapeLightRig(TFrame.position(i), normal, SPOTLIGHTS);

        float4 vertex = TFrame.color(i);
        float3 tint = vertex.xyz + vertex.xyz;
        float3 total = sum.ambient + sum.diffuse;
        LandscapeLit l;
        l.ambient = sum.ambient * tint;
        l.debug = total * tint;
        l.lit = max(l.debug, tint * sum.directional);
        l.specular = sum.specular;
        l.alpha = vertex.w * Factor.w;
        return l;
    }
    public static float fog(D3Interpolants i) { return TFog.factor(i); }
    public static float fogAlpha(float alpha, float fog) { return TFog.alpha(alpha, fog); }
};

// ---------------------------------------------------------------------------
// Gloss
// ---------------------------------------------------------------------------

/// The glossy reflection added to the lit albedo, and its debug channel. The
/// gloss colour arrives already masked by the diffuse alpha.
public interface ILandscapeGloss
{
    static float3 reflect(D3Interpolants i, float3 color, float3 gloss, float lightMapVisibility);
    static float3 debug(float3 color, float3 gloss);
}

public struct GlossNone : ILandscapeGloss
{
    public static float3 reflect(D3Interpolants i, float3 color, float3 gloss, float lightMapVisibility) { return color; }
    public static float3 debug(float3 color, float3 gloss) { return color; }
};

/// A projective environment map (TEXCOORD5.xy / .z) plus the gloss colour
/// itself where the light map sees the sun; dbgReg0.z shows the gloss colour.
public struct GlossEnvironment : ILandscapeGloss
{
    public static float3 reflect(D3Interpolants i, float3 color, float3 gloss, float lightMapVisibility)
    {
        float3 env = environmentMapSampler.Sample(environmentMapSampler_s, i.texcoord5().xy / i.texcoord5().z).rgb;
        return color + (gloss * env + gloss * lightMapVisibility);
    }
    public static float3 debug(float3 color, float3 gloss) { return dbgReg0.z * gloss + color; }
};

/// The light-map terms and the shaded light of one terrain pixel.
public struct LandscapeTerms
{
    /// the light map's baked sun visibility
    public float visibility;
    /// the light scaled by shadow and occlusion
    public float3 lighting;
};

/// Samples the light map (.w sun visibility, .x occlusion), darkens its
/// visibility by the sun shadow and applies both to the light.
public LandscapeTerms landscapeTerms<TShadow : ILandscapeShadow, TOcclusion : ILandscapeOcclusion>(
    D3Interpolants i, LandscapeLit light, float4 shadowCoord, float2 lightMapUv)
{
    LandscapeTerms t;
    float4 lightMap = lightMapSampler.Sample(lightMapSampler_s, lightMapUv);
    t.visibility = landscapeBakedTerm(lightMap.w, ShadowColor.z);
    float shadow = min(t.visibility, TShadow.visibility(shadowCoord));
    float occlusion = landscapeBakedTerm(TOcclusion.occlusion(i, lightMap.x), ShadowColor.w);
    t.lighting = lerp(light.ambient, light.lit, shadow) * occlusion;
    return t;
}
