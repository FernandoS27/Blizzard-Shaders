// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Water pixel shader entry point — Warcraft III Reforged 3.0.0.
//
// 3.0.0 grew water from 4 permutations to 128 and moved it onto the HD mesh's
// banks, but unlike foliage and terrain this is not a bank move: the shading is
// new. What water takes from HD is the machinery -- the main light's ambient
// and IBL arithmetic, the clustered light loop with point shadows and the debug
// overlay, the cascade shadow walk, the blight tint. What is water's own is the
// surface: four scrolling taps of a ripple map, Snell refraction against the
// scene colour and depth behind it, a depth-faded shore and glow, a
// reflection layer, and -- on the SSR permutations -- a hierarchical
// screen-space reflection march.
//
// Permutations (a 7-bit mask, folded to 49 programs):
//
//   bit 0 (  1)  SHADOW_CASCADE2 -> HAS_SHADOW_CASCADE2 (needs SHADOW_CASCADE)
//   bit 1 (  2)  DEPTH_PREPASS   -> WC3_IS_DEPTH_PREPASS: an EMPTY program
//   bit 2 (  4)  LIGHT_DEBUG     -> HAS_LIGHT_DEBUG
//   bit 3 (  8)  POINT_SHADOWS   -> HAS_POINT_SHADOWS
//   bit 4 ( 16)  SHADOW_CASCADE  -> HAS_SHADOW_CASCADE
//   bits 5-6     SSR quality     -> SSR_STEPS: 0 / 16 / 32 / 64 coarse steps
//
// There is no LIGHTING axis (water is always lit), no ALPHA_TEST, and no
// MULTI_TARGET axis because every shaded permutation writes both targets.
//
// As in 2.0.0, the shading normal and position are VIEW space; the probes are
// addressed by rotating into world space through `invView` with the engine's
// (x, z, -y) shuffle.

implementing wc3_shaders;

static const float4 WATER_RIPPLE_SCROLL  = float4(0.00350000034, 0.00350000034,
                                                  0.0299999975, 0.0299999975);
static const float4 WATER_RIPPLE_TILING  = float4(0.0140000004, 0.0140000004,
                                                  0.119999997, 0.119999997);
// Shoreline flattening: the ripples fade out as the vertex alpha drops.
static const float  WATER_FLATTEN_BIAS   = 0.400000006;
// Snell at an air / water interface: eta = 1 / 1.33, and its square.
static const float  WATER_ETA            = 0.751879692;
static const float  WATER_ETA_SQ         = 0.565323055;
static const float2 WATER_REFRACT_SCALE  = float2(0.0199999996, -0.00400000019);
// Refraction fades in over the first 45 units of water depth.
static const float  WATER_REFRACT_DEPTH  = 0.0222222228;
// Water's fixed roughness, before specular anti-aliasing.
static const float  WATER_ROUGHNESS      = 0.167500004;
static const float  WATER_SHADOW_JITTER  = 0.100000001;
static const float  WATER_SHORE_DEPTH    = 0.550000012;
static const float  WATER_FADE_SCALE_MIN = 9.99999975e-05;

// ---------------------------------------------------------------------------
// Surface
// ---------------------------------------------------------------------------

// Two octaves of the ripple map, each tapped forward and backward: the small
// octave's two normals are averaged, and the large octave's two XYs are added
// on top at half weight. Unnormalised -- the caller needs both the raw
// direction (for the shadow jitter) and the flattened one.
float3 waterRippleNormal(float2 uv, float time)
{
    float4 scroll = frac(WATER_RIPPLE_SCROLL * time);
    float4 uvFwd = uv.xyxy * WATER_RIPPLE_TILING + scroll;
    float4 uvBwd = (float4(-0.5, 0.5, -0.5, 0.5) + uv.xyxy) * WATER_RIPPLE_TILING - scroll;

    float3 smallFwd = decodeNormalMap(t_waterNormal.Sample(s_waterNormal, uvFwd.xy).xyw);
    float3 smallBwd = decodeNormalMap(t_waterNormal.Sample(s_waterNormal, uvBwd.xy).xyw);
    float3 largeFwd = decodeNormalMap(t_waterNormal.Sample(s_waterNormal, uvFwd.zw).xyw);
    float3 largeBwd = decodeNormalMap(t_waterNormal.Sample(s_waterNormal, uvBwd.zw).xyw);

    float3 n = 0.5 * (smallFwd + smallBwd);
    n.xy = 0.5 * (largeFwd.xy + largeBwd.xy) + n.xy;
    return n;
}

// The clamped texel a screen UV lands on.
int2 waterTexel(float2 uv, uint w, uint h)
{
    int2 texel = int2(floor(float2(w, h) * uv));
    return min(max(texel, int2(0, 0)), int2(w, h) - int2(1, 1));
}

// ---------------------------------------------------------------------------
// Probes
// ---------------------------------------------------------------------------

// A view-space direction in probe space: world, via invView, with the (x, z, -y)
// shuffle the cube maps are stored in (the -y lands at sample time).
float3 waterToProbe(float3 v)
{
    return normalize(mul((float3x3)hdPsCB2.invView, v).xzy);
}

// The probe pair at a probe-space direction, blended across the transition.
float3 waterProbeBlend(float4 coord)
{
    float3 from = t_hdIblFrom.Sample(s_hdIblFrom, coord).xyz;
    float3 to = t_hdIblTo.Sample(s_hdIblTo, coord).xyz;
    return hdPsCB2.envTransitionT * (to - from) + from;
}

// The main light's probe sample, in water's basis. Irradiance at the normal,
// radiance at the reflection at the roughness mip, and the BRDF LUT.
struct WaterProbeSampler : IHDProbeSampler
{
    float3 normalProbe;
    float4 reflectCoord;

    HDIBLSample sample(float3 viewPos, HDSurface s)
    {
        return sampleWaterIBL(normalProbe, reflectCoord, s);
    }
}

HDIBLSample sampleWaterIBL(float3 normalProbe, float4 reflectCoord, HDSurface s)
{
    HDIBLSample ibl;
    if (hdPsCB2.envFromMipEnd * hdPsCB2.envToMipEnd != 0.0)
    {
        ibl.irradiance = waterProbeBlend(float4(normalProbe * float3(1, 1, -1), 0));

        float2 mip = float2(hdPsCB2.envFromMipEnd, hdPsCB2.envToMipEnd) * s.rough;
        float3 radA = t_hdIblFrom.SampleLevel(s_hdIblFrom, reflectCoord, mip.x).xyz;
        float3 radB = t_hdIblTo.SampleLevel(s_hdIblTo, reflectCoord, mip.y).xyz;
        ibl.radiance = hdPsCB2.envTransitionT * (radB - radA) + radA;

        ibl.brdf = t_hdBrdfLut.Sample(s_hdBrdfLut, float2(dot(s.N, s.V), s.rough)).xy;
        ibl.weight = 1;
    }
    else
    {
        ibl.irradiance = float3(0, 0, 0);
        ibl.radiance = float3(0, 0, 0);
        ibl.brdf = float2(0, 0);
        ibl.weight = 0;
    }
    return ibl;
}

// ---------------------------------------------------------------------------
// Screen-space reflection
// ---------------------------------------------------------------------------

// The reflected colour and its weight, or zero weight when the march finds
// nothing -- and always on the permutations without SSR.
//
// A hierarchical screen-space DDA. The reflection ray is clipped to a 500-unit
// segment and projected into depth-buffer pixels; a COARSE DDA then walks the
// 64x64 tile grid of t2, whose .x / .y bound each tile's depth, for at most
// SSR_STEPS tiles. Only a tile the ray's depth span can intersect is walked
// FINELY, pixel by pixel against t1, for at most one tile's width plus two
// pixels. Depth is interpolated perspective-correctly along the segment as
// (t * dq + q0) / (t * dk + k0). A pixel hit returns the scene colour there,
// weighted down near the screen edge and with distance travelled -- faster the
// fewer coarse steps the permutation takes (fade x5 / x1.667 / x1).
//
// Both DDAs step the axis whose next boundary is nearer, and on a tie the Y
// axis: the shipped comparison is a strict `<` on X.
static const float WATER_SSR_RAY_LENGTH = 500.0;
static const float WATER_SSR_TILES      = 64.0;
static const float WATER_SSR_TILE_SIZE  = 0.015625;   // 1 / 64
static const float WATER_SSR_EPS        = 1.0e-20;
static const float WATER_SSR_THICKNESS  = 2.0;
static const float WATER_SSR_EDGE_FADE  = 12.5;

// Perspective-correct depth at parameter t along the projected segment.
float waterSSRDepth(float t, float dq, float q0, float dk, float k0)
{
    return (t * dq + q0) / (t * dk + k0);
}

// The travel fade rate per quality: the more coarse steps, the slower it fades.
float waterSSRFade<let SSR_STEPS : uint>()
{
    if (SSR_STEPS == 16)
        return 5.0;
    if (SSR_STEPS == 32)
        return 1.66666663;
    return 1.0;
}

float4 waterReflectionMarch<let SSR_STEPS : uint>(
    float3 viewPos, float3 V, float3 N, uint depthW, uint depthH)
{
    float4 result = float4(0, 0, 0, 0);
    if (SSR_STEPS == 0)
        return result;

    float nv = dot(-V, N);
    float3 R = normalize(N * -(nv + nv) + -V);
    float3 rayEnd = R * WATER_SSR_RAY_LENGTH + viewPos;

    float3 h0 = hdViewToClipXYW(viewPos);
    float3 h1 = hdViewToClipXYW(rayEnd);
    if ((abs(h0.z) < 9.99999975e-06) || (abs(h1.z) < 9.99999975e-06))
        return result;

    float2 p0 = hdClipToDepthUV(h0);
    float2 delta = hdClipToDepthUV(h1) - p0;
    float2 tileDelta0 = delta * WATER_SSR_TILES;
    if (!(max(abs(tileDelta0.y), abs(tileDelta0.x)) >= 1))
        return result;

    float k0 = 1.0 / h0.z;
    float k1 = 1.0 / h1.z;
    float q0 = viewPos.z * k0;
    float2 dims = float2(depthW, depthH);
    float2 invDims = 1.0 / dims;
    float2 pix0 = dims * p0;
    float2 pixDelta = dims * delta;
    uint fineSteps = (uint)ceil(dims.y * WATER_SSR_TILE_SIZE
                                + dims.x * WATER_SSR_TILE_SIZE) + 2;
    float fade = waterSSRFade<SSR_STEPS>();

    // Coarse DDA state, in tile units.
    bool2 forward = delta >= float2(0, 0);
    float2 tileDelta = delta * WATER_SSR_TILES
                     + ((delta == float2(0, 0)) ? WATER_SSR_EPS : float2(0, 0));
    int2 tile = (int2)floor(p0 * WATER_SSR_TILES);
    int2 tileStep = forward ? int2(1, 1) : int2(-1, -1);
    float2 tileInvDelta = 1.0 / abs(tileDelta);
    float2 tileTMax = ((float2)(tile - (forward ? int2(-1, -1) : int2(0, 0)))
                       - p0 * WATER_SSR_TILES) / tileDelta;

    float dk = k1 - k0;
    float dq = rayEnd.z * k1 - q0;

    // Fine DDA constants, in pixel units.
    bool2 pixForward = pixDelta >= float2(0, 0);
    float2 pixDeltaSafe = delta * dims
                        + ((pixDelta == float2(0, 0)) ? WATER_SSR_EPS : float2(0, 0));
    int2 pixStep = pixForward ? int2(1, 1) : int2(-1, -1);
    float2 pixInvDelta = 1.0 / abs(pixDeltaSafe);
    int2 maxTexel = int2(depthW, depthH) - int2(1, 1);

    float t = 0;
    [loop] for (uint i = 0; i < SSR_STEPS; i++)
    {
        float2 centre = ((float2)tile + 0.5) * WATER_SSR_TILE_SIZE;
        if (any(centre != saturate(centre)))
            break;

        float tEnd = min(tileTMax.y, tileTMax.x);
        float zA = waterSSRDepth(t, dq, q0, dk, k0);
        float zB = waterSSRDepth(tEnd, dq, q0, dk, k0);
        float zMin = min(zB, zA);
        float zMax = max(zB, zA);
        float2 bounds = t_waterDepthHiZ.Load(int3(tile, 0)).xy;

        bool found = false;
        if ((0 < zMax - bounds.x) && (zMin - bounds.y < WATER_SSR_THICKNESS))
        {
            float2 pix = pixDelta * t + pix0;
            int2 pixI = (int2)floor(pix);
            float2 pixTMax = ((float2)(pixI - (pixForward ? int2(-1, -1) : int2(0, 0)))
                              - pix) / pixDeltaSafe + t;
            float tf = t;

            [loop] for (uint j = 0; j < fineSteps; j++)
            {
                if (tf >= tEnd)
                    break;
                int2 texel = min(maxTexel, max(pixI, int2(0, 0)));
                float tn = min(tEnd, min(pixTMax.y, pixTMax.x));
                float fA = waterSSRDepth(tf, dq, q0, dk, k0);
                float fB = waterSSRDepth(tn, dq, q0, dk, k0);
                float sceneZ = t_waterDepth.Load(int3(texel, 0)).x;
                if ((0 < max(fB, fA) - sceneZ)
                    && (WATER_SSR_THICKNESS >= min(fB, fA) - sceneZ))
                {
                    float2 hitPix = pixDelta * ((tf + tn) * 0.5) + pix0;
                    float2 hitUV = invDims * hitPix;
                    float travel = min(1.0, fade * length(hitUV - pix0 * invDims));
                    float travelFade = -(travel * -2 + 3) * (travel * travel) + 1;
                    float2 edge2 = min(1.0 - hitPix * invDims, hitUV);
                    float edge = saturate(WATER_SSR_EDGE_FADE * min(edge2.y, edge2.x));
                    float edgeFade = (edge * edge) * (edge * -2 + 3);
                    result = float4(t_waterScene.Load(int3(texel, 0)).xyz,
                                    min(edgeFade, travelFade));
                    found = true;
                    break;
                }
                if (pixTMax.x < pixTMax.y)
                {
                    tf = pixTMax.x;
                    pixTMax.x = pixInvDelta.x + pixTMax.x;
                    pixI.x = pixStep.x + pixI.x;
                }
                else
                {
                    tf = pixTMax.y;
                    pixTMax.y = pixInvDelta.y + pixTMax.y;
                    pixI.y = pixStep.y + pixI.y;
                }
            }
        }
        if (found)
            break;

        if (tileTMax.x < tileTMax.y)
        {
            t = tileTMax.x;
            tileTMax.x = tileInvDelta.x + tileTMax.x;
            tile.x = tileStep.x + tile.x;
        }
        else
        {
            t = tileTMax.y;
            tileTMax.y = tileInvDelta.y + tileTMax.y;
            tile.y = tileStep.y + tile.y;
        }
    }
    return result;
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

[shader("fragment")]
public WaterPSOutput water_ps_main<
    let HAS_SHADOW_CASCADE  : bool,
    let HAS_SHADOW_CASCADE2 : bool,
    let HAS_POINT_SHADOWS   : bool,
    let HAS_LIGHT_DEBUG     : bool,
    let SSR_STEPS           : uint
>(WaterPSInput input)
{
    WaterPSOutput output;

#if WC3_IS_DEPTH_PREPASS
    {
        return output;
    }
#else
    {

    bool constantProbe = 0.5 < hdPsCB1.waterProbeColor.w;

    uint sceneW, sceneH, sceneMips;
    t_waterScene.GetDimensions(0, sceneW, sceneH, sceneMips);
    float2 screenUV = input.svPosition.xy / (float2)int2(sceneW, sceneH);

    // --- the rippled surface normal ---------------------------------------
    float3 ripple = waterRippleNormal(input.uv.xy, hdPsCB2.effectTime);
    float invRipple = rsqrt(dot(ripple, ripple));
    float flatten = saturate(hdPsCB1.waterRippleStrength
                             * min(1.0, input.vertColor.w * input.vertColor.w
                                        + WATER_FLATTEN_BIAS));
    float3 tsN = normalize(flatten * (ripple * invRipple + float3(0, 0, -1))
                           + float3(0, 0, 1));
    float3 N = tangentToWorld(tsN, input.tangentVS.xyz, input.normalVS, input.tangentVS.w);

    float invViewDist = rsqrt(dot(-input.viewPos, -input.viewPos));
    float3 V = -input.viewPos * invViewDist;

    // --- refraction: offset along the Snell direction, faded in with depth --
    uint depthW, depthH, depthMips;
    t_waterDepth.GetDimensions(0, depthW, depthH, depthMips);
    float centerDepth = t_waterDepth.Load(int3(waterTexel(screenUV, depthW, depthH), 0)).x;

    float ndv = dot(V, N);
    float cosT2 = -(-ndv * ndv + 1) * WATER_ETA_SQ + 1;
    float bend = ndv * WATER_ETA + sqrt(cosT2);
    float2 refractDir = (cosT2 >= 0) ? (V.xy * WATER_ETA - bend * N.xy) : float2(0, 0);
    refractDir = input.viewPos.xy * invViewDist + refractDir;
    float2 refractOffset = WATER_REFRACT_SCALE * refractDir;

    float depthBelow = centerDepth - input.viewPos.z;
    float refractFade = saturate(WATER_REFRACT_DEPTH * depthBelow);
    float2 offset = refractOffset * refractFade;
    float offsetDepth = t_waterDepth.Load(
        int3(waterTexel(refractOffset * refractFade + screenUV, depthW, depthH), 0)).x;

    // A refracted tap that lands on something IN FRONT of the water would
    // show that object through the surface; take the straight-through texel.
    float3 refracted = (offsetDepth < input.viewPos.z) ? float3(0, 0, centerDepth)
                                                       : float3(offset, offsetDepth);
    float3 scene = t_waterScene.Load(
        int3(waterTexel(refracted.xy + screenUV, sceneW, sceneH), 0)).xyz;

    // --- the reflection ray and the environment it sees --------------------
    float4 ssr = waterReflectionMarch<SSR_STEPS>(input.viewPos, V, N, depthW, depthH);

    float3 posProbe = waterToProbe(input.viewPos);
    float3 normalProbe = waterToProbe(N);
    float d = dot(posProbe, normalProbe);
    float3 reflectProbe = normalize(normalProbe * -(d + d) + posProbe);
    float4 reflectCoord = float4(float3(1, 1, -1) * reflectProbe, 1);
    float3 envReflect = waterProbeBlend(reflectCoord);

    // --- the water colour ---------------------------------------------------
    float3 probe;
    float3 glowClamp;
    float3 tint;
    if (constantProbe)
    {
        probe = hdPsCB1.waterProbeColor.xyz;
        glowClamp = hdPsCB1.waterProbeColor.xyz;
        tint = float3(1, 1, 1);
    }
    else
    {
        probe = t_waterProbe.SampleLevel(s_waterProbe, float2(0, 0), 16).xyz;
        tint = srgbToLinear(input.vertColor.xyz);
        glowClamp = hdPsCB2.waterGlowClamp();
    }

    // --- lighting: HD's main light and cluster loop, on a black dielectric
    //     whose albedo is the water colour ---------------------------------
    float rough = (asuint(hdPsCB2.useNdf) != 0) ? specularAA(WATER_ROUGHNESS, N)
                                                : WATER_ROUGHNESS;
    HDSurface surf = hdSurfaceFromRough(N, V, probe, 0.0, rough);

    // The ripples wobble the shadows they receive: the cascade walk starts from
    // this offset and the point-light kernels are pushed along it.
    float3 shadowJitter = (WATER_SHADOW_JITTER * hdPsCB1.waterRippleStrength)
                        * (ripple * invRipple);

    float mainShadow = 1;
    if (HAS_SHADOW_CASCADE)
        mainShadow = hdMainLightShadowJittered<HAS_SHADOW_CASCADE2>(
            input.worldPos, shadowJitter.xy);

    float3 lit = float3(0, 0, 0);
    if (asint(hdPsCB2.mainLightEnable) != 0)
    {
        WaterProbeSampler probeSampler;
        probeSampler.normalProbe = normalProbe;
        probeSampler.reflectCoord = reflectCoord;
        lit = hdMainLightWith<WaterProbeSampler>(surf, input.viewPos, mainShadow, 1.0,
                                                 probeSampler);
    }
    lit = hdClusterLightsOffset<HAS_POINT_SHADOWS, HAS_LIGHT_DEBUG, true>(
        surf, input.viewPos, input.worldPos.xyz, input.svPosition.xy, lit, shadowJitter);
    lit = PI * lit;

    // --- composite ------------------------------------------------------------
    // How far the water fades in from the shore, eased.
    float fade = saturate(depthBelow / hdPsCB2.waterDeepDepth);
    fade = min(1.0, fade * (1.0 / max(WATER_FADE_SCALE_MIN, hdPsCB1.waterFadeScale)));
    fade = (fade * -2 + 3) * (fade * fade);

    float3 blight = hdBlightTint(input.uv.zw);
    float3 litTint = min(lit, tint) * blight;
    float3 glow = min(glowClamp, probe) * litTint;

    float refractedBelow = (refracted.z - input.viewPos.z) * WATER_SHORE_DEPTH;
    float2 shore = saturate(refractedBelow / float2(hdPsCB2.waterDeepDepth,
                                                    hdPsCB2.waterShallowDepth));

    // Two ways to see through the water. The artist range, when one is set...
    bool artistRange = (0 < hdPsCB1.waterRefractMin) || (hdPsCB1.waterRefractMax < 1);
    float rangeT = shore.x * (max(hdPsCB1.waterRefractMax, hdPsCB1.waterRefractMin)
                              - hdPsCB1.waterRefractMin) + hdPsCB1.waterRefractMin;
    rangeT = min(rangeT, fade);
    float3 throughRange = (glow * blight - scene) * rangeT + scene;

    // ...and otherwise the lit scene, then the glow, each faded in by depth.
    float glowT = (shore.x * shore.x - shore.x) * 0.25 + shore.x;
    float3 through = ((probe * scene) * litTint * blight - scene) * shore.y + scene;
    through = (glow * blight - through) * glowT + through;
    through = artistRange ? throughRange : through;

    float3 reflectEnv = envReflect * blight * hdPsCB1.waterReflectScale;
    float3 reflection = (ssr.xyz - reflectEnv) * ssr.w + reflectEnv;
    float3 rgb = (reflection - through) * (hdPsCB1.waterReflectStrength * fade) + through;

    float3 glowAdd = (hdPsCB1.waterGlowStrength * probe) * fade;
    output.color = float4(glowAdd * blight + rgb, 1);
    output.depth = float4(input.viewPos.z, 0, 0, 1);
    return output;

    }
#endif
}
