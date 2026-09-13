// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Shared image-based-lighting and analytical-light helpers for the 2.0.0
// pipelines: the IBL probe blend, the "Blizzard ambient" mix, and the
// fixed-size analytical light loop.
//
// The full `psIBLBody` that used to live here is gone with the entry points
// that called it — `hd_ps` is 3.0.0 now (ps/hd_ps_lighting.slang) and the
// toon / gritty variants were deleted. What remains is the part crystal_ps,
// sd_on_hd_ps, terrain_ps and water_ps still call.
//
// The IBL probe blend uses two cubemap-array bindings (`from`, `to`) so
// the runtime can smoothly transition environments; `envTransitionT` is
// the lerp factor and `envFromMipEnd` / `envToMipEnd` pick the
// roughness-mapped mip for each probe independently (allowing the two
// probes to have different resolutions / mip counts).

implementing wc3_shaders;

// Split factors for the Blizzard ambient mix. The analytical-ambient
// contribution is decomposed into two pieces — an "upper" path that
// blends between the probe and the light's ambient color and a "lower"
// path that is scaled down by the NdotL coverage so unlit sides darken
// gracefully as the diffuse light fades out.
static const float BLIZZARD_AMBIENT_SPLIT_UPPER = 0.675000012;
static const float BLIZZARD_AMBIENT_SPLIT_LOWER = 0.324999988;

public struct IBLSampleResult
{
    public float3 diffuseIrradiance;
    public float3 specularRadiance;
    public float2 brdfLUT;
    public float  isActive;   // 0 when no probes are bound, 1 otherwise.
};

// Sample both the "from" and "to" IBL probes, blend them, and fetch the
// split-sum BRDF LUT. When either probe is absent (`envFromMipEnd *
// envToMipEnd == 0`) the result is cleared and `isActive = 0`, letting
// the caller skip the IBL contribution altogether.
//
// The `xzy` swizzles on the world-space vectors + the (1,1,-1) flip in
// the cubemap coord convert from the engine's Z-up world to the
// cubemap's Y-up, right-handed sampling convention.
public IBLSampleResult sampleIBL(
    float3 viewPos, float3 viewNormal, float roughnessAA,
    float4x4 worldToView, float envFromMipEnd, float envToMipEnd, float envTransitionT)
{
    IBLSampleResult result;

    // Fast-out when no probes are bound.
    float iblTest = envFromMipEnd * envToMipEnd;
    if (iblTest != 0.0)
    {
        // Remap the engine's view-space vectors into the probe cubemap's
        // sampling basis. `worldToView` is kept here because the engine's
        // uploaded matrix matches the probe-space rotation expected by the
        // original shader path.
        float3 probePosDir    = normalize(mul((float3x3)worldToView, viewPos).xzy);
        float3 probeNormalDir = normalize(mul((float3x3)worldToView, viewNormal).xzy);

        // Reflection vector for the specular lobe sample.
        float VdotN = dot(probePosDir, probeNormalDir);
        float3 reflDir = probePosDir - probeNormalDir * (VdotN + VdotN);
        reflDir = normalize(reflDir);

        // Diffuse irradiance sampled at mip 0 (slice 0).
        float4 diffCoord = float4(probeNormalDir * float3(1, 1, -1), 0);
        float3 diffFrom = t_iblFrom.Sample(s_iblFrom, diffCoord).xyz;
        float3 diffTo   = t_iblTo.Sample(s_iblTo, diffCoord).xyz;
        result.diffuseIrradiance = envTransitionT * (diffTo - diffFrom) + diffFrom;

        // Specular radiance at the roughness-mapped mip of each probe
        // (slice 1 holds the pre-convolved specular levels).
        float2 mipLevels = float2(envFromMipEnd, envToMipEnd) * roughnessAA;
        float4 specCoord = float4(reflDir * float3(1, 1, -1), 1);
        float3 specFrom = t_iblFrom.SampleLevel(s_iblFrom, specCoord, mipLevels.x).xyz;
        float3 specTo   = t_iblTo.SampleLevel(s_iblTo, specCoord, mipLevels.y).xyz;
        result.specularRadiance = envTransitionT * (specTo - specFrom) + specFrom;

        // Split-sum BRDF LUT: x is the Fresnel scale, y is the bias.
        // We pass the unclamped NdotV so glancing pixels are allowed to
        // darken past zero, which is what the LUT was baked against.
        float NdotV_unclamped = dot(viewNormal, normalize(-viewPos));
        float2 lutCoord = float2(NdotV_unclamped, roughnessAA);
        result.brdfLUT = t_brdfLut.Sample(s_brdfLut, lutCoord).xy;
        result.isActive = 1.0;
    }
    else
    {
        result.diffuseIrradiance = float3(0, 0, 0);
        result.specularRadiance = float3(0, 0, 0);
        result.brdfLUT = float2(0, 0);
        result.isActive = 0.0;
    }
    return result;
}

// The "Blizzard ambient" mix.
//
// Given the first analytical light's ambient term and the IBL diffuse
// irradiance, this produces a blend that:
//   - uses the analytical ambient when no IBL probe is active,
//   - matches the probe hue when it is,
//   - fades smoothly between the two depending on the relative
//     intensity of the probe vs. the analytical ambient (maxAmbient),
//   - and additionally darkens the "shadow side" (low NdotL) using
//     the `lower` split so unlit areas don't look flat.
public float3 blizzardAmbientBlend(
    float3 analyticalAmbient, float3 diffuseIBL,
    float NdotL, float maxAmbient, float iblActive, float ambientWeight)
{
    float safeDenom = 1.0 / (maxAmbient + SAFE_EPS);
    float totalWeight = maxAmbient + iblActive;
    float ambientIBLWeight = totalWeight * iblActive;
    ambientIBLWeight = ambientWeight * ambientIBLWeight;

    // Hue-separate both terms so the mix preserves saturation.
    float maxDiffIBL = max(max(diffuseIBL.x, diffuseIBL.y), diffuseIBL.z);
    float3 normIBL = diffuseIBL / (maxDiffIBL + SAFE_EPS);

    float3 normAmbient = analyticalAmbient * safeDenom;
    float3 delta = normAmbient - normIBL;

    // "Upper" term — dominant when the surface is lit (high NdotL).
    float3 upper = delta * BLIZZARD_AMBIENT_SPLIT_UPPER + normIBL;
    upper *= maxDiffIBL;
    upper = upper * totalWeight - analyticalAmbient;
    upper = iblActive * upper + analyticalAmbient;

    // "Lower" term — dominant on the shadow side (low NdotL).
    float3 lower = delta * BLIZZARD_AMBIENT_SPLIT_LOWER + normIBL;
    lower *= maxDiffIBL;

    float3 lowerScaled = lower * ambientIBLWeight;
    float3 result = NdotL * (upper - lowerScaled) + lowerScaled;
    return result;
}

// Analytical light loop. Runs Cook-Torrance + Lambert per light and
// accumulates into `accum`. The first directional light, if any, is
// handled separately by the caller (it also runs the Blizzard ambient
// blend); `startLight` is the loop index to resume from. All the
// roughness-dependent BRDF constants (a², a⁴, k) are pre-hoisted
// outside the loop since they don't change across lights.
public float3 lightLoop(
    float3 viewPos, float3 viewNormal, float3 viewDir, float viewDirLen,
    float3 F0, float3 oneMinusF0, float3 lambertianDiffuse,
    float roughnessAA, float NdotV_precomp,
    uint startLight)
{
    // Hoisted constants — used to reconstruct D (GGX) and V (Schlick-GGX).
    float a2 = roughnessAA * roughnessAA;
    float a4 = a2 * a2;
    float a4m1 = a4 - 1.0;

    float a1 = 1.0 + roughnessAA;
    float a12 = a1 * a1;
    float k = a12 * SCHLICK_K_FACTOR;
    float oneMinusK = 1.0 - k;
    float gvDenom = NdotV_precomp * oneMinusK + k;

    float3 accum = float3(0, 0, 0);
    uint lightIdx = startLight;

    while (true)
    {
        if (lightIdx >= asuint(psCB2.lightCount))
            break;

        ShaderLight light = psCB2.lights[lightIdx];
        float3 lightDir;
        float attenuation;

        if (light.position.w > 0)
        {
            // Point light: direction toward the light + the retail SD/HD
            // falloff `1 / (1 + POINT_EPS * distSq)` — bounded at 1 near
            // the light, NOT the `pointLightAttenuation` inverse-square
            // form (that helper is for the popcorn path). Matches the
            // `1.0 + 0.0005 * distSq` denominator in the shipped DXBC.
            float3 lightVec = light.position.xyz - viewPos;
            float distSq = dot(lightVec, lightVec);
            float dist = sqrt(distSq);
            attenuation = pointLightAttenuation(distSq);
            lightDir = lightVec / dist;
        }
        else
        {
            // Directional light: position is already the unit direction.
            lightDir = light.position.xyz;
            attenuation = 1.0;
        }

        // Evaluate the Cook-Torrance components inline so the compiler
        // can share intermediates (H, VdotH, NdotH) across D/F/V.
        float3 H = normalize(viewDir + lightDir);
        float VdotH = dot(H, viewDir);
        float NdotH = dot(viewNormal, H);
        float NdotL = dot(viewNormal, lightDir);

        // Schlick Fresnel (F = F0 + (1-F0)(1-VdotH)^5).
        float t = 1.0 - VdotH;
        float t2 = t * t;
        float t5 = t2 * t2 * t;
        float3 F = oneMinusF0 * t5 + F0;

        // GGX normal distribution.
        float nh2 = NdotH * NdotH;
        float denom = nh2 * a4m1 + 1.0;
        float D = a4 / (PI * denom * denom);

        // Schlick-GGX visibility (half of the classic G/(4·NdotL·NdotV)).
        float glDenom = NdotL * oneMinusK + k;
        float V = saturate(1.0 / (4.0 * glDenom * gvDenom));

        float clampedNdotL = max(0.0, NdotL);
        float contribution = attenuation * clampedNdotL;

        // Direct-light contribution: (diffuse + specular) * light color.
        float3 specular = D * F * V;
        float3 brdf = specular + lambertianDiffuse;
        accum += light.diffuse.xyz * brdf * contribution;

        // Per-light ambient (attenuated, independent of NdotL) —
        // matches the analytical-ambient term the engine uploads.
        accum += light.ambient.xyz * lambertianDiffuse * attenuation;

        lightIdx++;
    }
    return accum;
}
