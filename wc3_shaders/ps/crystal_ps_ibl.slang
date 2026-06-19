// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// IBL crystal pixel shader body.
//
// Mirrors `psIBLBody` but threads the crystal albedo refraction into the
// shading pipeline:
//   1. Refract-sample the albedo (centre + offset lerp by 1-refractMask).
//   2. Fetch the full ORM vector (refract, roughness, metalness, blend).
//   3. Run the same Cook-Torrance + IBL + analytical light loop the HD
//      path uses, unchanged — the BRDF math only cares about albedo /
//      roughness / metalness values, not where they came from.
//   4. Apply the fresnel overlay with a refract-modulated alpha so the
//      hero rim stays visible through a fully refracted body.
//   5. Cloak runs last, same as the HD path.
//
// The IBL sample, analytical-light loop, Blizzard ambient blend, fresnel
// overlay, multi-layer blend, and cloak are all shared verbatim with
// `psIBLBody` — see their respective files for the algorithm details.

implementing wc3_shaders;

public float4 crystalIBLBody<
    TMat : IMaterialLayer,
    let HAS_EXTRA_VERTS : bool,
    let HAS_DEBUG_VIS : bool>(
    PSInput input, bool isFrontFace, out float3 dbgOverlay)
{
    // Debug overlay (modes 5-7); assigned once the lit terms are known.
    dbgOverlay = float3(0, 0, 0);
    // --- Texture sampling ---
    // Crystal packs (refract, roughness, metalness, blendWeight) into the
    // ORM slot. Read all four channels for the IBL path — the non-IBL
    // bodies only need .x / .w and fetch a narrower swizzle.
    float4 orm = t_orm.Sample(s_orm, input.uv.xy);
    float  refractMask = orm.x;
    float  roughness   = orm.y;
    float  metalness   = orm.z;
    float  blendWeight = orm.w;

    // DEBUG_VIS bit 1: override the entire ORM triplet with cb3's
    // override (the scalar form only overrides refractMask, but the IBL
    // path uses .xyz so artists can dial in roughness / metal too).
    if (HAS_DEBUG_VIS && (asuint(psCB3.enabledShaders) & 2) != 0)
    {
        refractMask = psCB3.overrideOrm.x;
        roughness   = psCB3.overrideOrm.y;
        metalness   = psCB3.overrideOrm.z;
    }

    // Refracted albedo (centre.w preserved for downstream alpha). The
    // DEBUG_VIS bit-0 override applies to the centre sample inside the
    // refraction blend, not the blended result.
    bool ovrAlbedo = HAS_DEBUG_VIS && (asuint(psCB3.enabledShaders) & 1) != 0;
    float4 albedo = sampleCrystalAlbedo(input.uv.xy, input.normalWS.xyz, refractMask,
                                        ovrAlbedo, psCB3.overrideAlbedo.xyz);

    float3 normalSample = t_normal.Sample(s_normal, input.uv.xy).xyw;
    float3 emissive = t_emissive.Sample(s_emissive, input.uv.xy).xyz;

    // Multi-layer team blend — identical to `psIBLBody` once albedo has
    // been produced, so we pipe the refracted albedo through the shared
    // `multiLayerBlend` helper.
    float3 teamAlbedo  = float3(0, 0, 0);
    float  teamLuma    = 0.0;
    if (TMat.hasMultiLayer)
    {
        teamAlbedo = t_teamColor.Sample(s_teamColor, input.uv.xy).xyz;
        teamLuma   = max(max(teamAlbedo.x, teamAlbedo.y), teamAlbedo.z);
        MultiLayerResult ml = multiLayerBlend(albedo.xyz, teamAlbedo, blendWeight, emissive);
        albedo.xyz = ml.albedo;
        emissive   = ml.emissive;
    }

    // --- Shadow cascade attenuation ---
    // 3-cascade PCF, applied to the first directional light's direct term
    // only (same as the HD path). Skipped when the VS didn't pass the
    // cascade clip coords (HAS_EXTRA_VERTS=false).
    float shadowAtten = 1.0;
#if WC3_HAS_SHADOWS
    if (HAS_EXTRA_VERTS)
    {
        shadowAtten = sdSampleShadowCascades(
            input.shadowClip0, input.shadowClip1, input.shadowClip2,
            asuint(sdPsCB1.numCascades));
    }
#endif

    // --- World-space normal + roughness specular-AA ---
    float3 tsNormal = decodeNormalMap(normalSample);
    float3 worldNormal = tangentToWorld(tsNormal, input.tangentWS.xyz, input.normalWS.xyz, input.tangentWS.w);
    worldNormal = orientNormal(worldNormal, isFrontFace);

    float roughnessMip = roughnessToMip(roughness);
    float roughnessAA  = psCB2.useNdf != 0 ? specularAA(roughnessMip, worldNormal) : roughnessMip;

    // --- View direction, F0, Lambertian diffuse ---
    float  viewDirLen = rsqrt(dot(-input.worldPos.xyz, -input.worldPos.xyz));
    float3 viewDir    = -input.worldPos.xyz * viewDirLen;

    float3 F0 = metalness * albedo.xyz;
    float3 diffuseAlbedo = (1.0 - metalness) * albedo.xyz;
    float3 lambertianDiffuse = INV_PI * diffuseAlbedo;

    float3 accum = float3(0, 0, 0);
    uint firstLightProcessed = 0;

    // --- First light + IBL blend (only if light 0 is directional) ---
    bool hasFirstLight     = asuint(psCB2.lightCount) > 0;
    bool firstIsDirectional = hasFirstLight && (psCB2.lights[0].position.w == 0.0);

    if (firstIsDirectional)
    {
        float3 lightDir = psCB2.lights[0].position.xyz;

        float3 H = normalize(viewDir + lightDir);
        float  VdotH = dot(H, viewDir);
        float  NdotH = dot(worldNormal, H);
        float  NdotL = dot(worldNormal, lightDir);
        float  NdotV = dot(worldNormal, viewDir);

        float3 F = schlickFresnel(F0, VdotH);
        float  D = ggxNDF(NdotH, roughnessAA);
        float  V = schlickGGXVisibility(NdotL, NdotV, roughnessAA);
        float3 spec = D * F * V;
        float  clampedNdotL = max(0.0, NdotL);

        // Shadow attenuates only the main directional light's direct
        // contribution (ambient blend + direct specular), not the indirect
        // IBL terms — matching the HD path and the retail DXBC.
        float  litNdotL = HAS_EXTRA_VERTS ? (clampedNdotL * shadowAtten) : clampedNdotL;

        IBLSampleResult ibl = sampleIBL(
            input.worldPos.xyz, worldNormal, roughnessAA,
            psCB2.view,
            psCB2.envFromMipEnd, psCB2.envToMipEnd, psCB2.envTransitionT);

        float maxDiffuse = max(max(psCB2.lights[0].diffuse.x, psCB2.lights[0].diffuse.y), psCB2.lights[0].diffuse.z);
        float ambientWeight = psCB2.lights[0]._pad2.x;

        float3 ambientResult = blizzardAmbientBlend(
            psCB2.lights[0].diffuse.xyz, ibl.diffuseIrradiance,
            litNdotL, maxDiffuse, ibl.isActive, ambientWeight);
        ambientResult += psCB2.lights[0].ambient.xyz;

        float totalWeight = maxDiffuse + ibl.isActive;
        float3 scaledSpec = spec * totalWeight * litNdotL;

        float3 indirectSpec = F0 * ibl.brdfLUT.x + ibl.brdfLUT.y;
        float  ambientIBLWeight = totalWeight * ibl.isActive * ambientWeight;
        indirectSpec *= ambientIBLWeight;
        indirectSpec += scaledSpec * psCB2.lights[0].diffuse.xyz;
        indirectSpec *= ibl.specularRadiance;

        float3 dbgDiffuse = ambientResult * lambertianDiffuse;
        accum = dbgDiffuse + indirectSpec;
        firstLightProcessed = 1;

        if (HAS_DEBUG_VIS)
        {
            // First-light IBL split for debug modes 5-7 (PI-scaled).
            int dm = asint(psCB3.debugMode);
            if (dm == 5)      dbgOverlay = PI * indirectSpec;
            else if (dm == 6) dbgOverlay = PI * dbgDiffuse;
            else if (dm == 7) dbgOverlay = PI * accum;
        }
    }

    // --- Remaining analytical lights ---
    float  NdotV_precomp = dot(worldNormal, viewDir);
    float3 oneMinusF0    = 1.0 - F0;
    accum += lightLoop(
        input.worldPos.xyz, worldNormal, viewDir, viewDirLen,
        F0, oneMinusF0, lambertianDiffuse,
        roughnessAA, NdotV_precomp,
        firstLightProcessed);

    // --- Assemble lit colour ---
    float3 finalColor = PI * accum;

    // Debug mode 8 = full lit colour (all lights, pre-emissive/vert/fresnel).
    if (HAS_DEBUG_VIS && asint(psCB3.debugMode) == 8)
        dbgOverlay = finalColor;

    finalColor += emissive * psCB2.emissiveGain;
    float3 linearVert = srgbToLinear(input.vertColor.xyz);
    finalColor *= linearVert;

    // --- Crystal-modulated Fresnel overlay ---
    float NdotV_sat = saturate(NdotV_precomp);
    float fresnelAlphaMod = refractModulatedFresnelAlpha(psCB2.fresnelColor.w, refractMask);

    FresnelOverlayResult fr;
    if (TMat.hasMultiLayer)
    {
        fr = applyFresnelOverlayML(
            finalColor, albedo.w, NdotV_sat,
            psCB2.fresnelColor.xyz, fresnelAlphaMod, psCB2.fresnelTeamColor,
            input.vertColor.w,
            teamAlbedo, teamLuma);
    }
    else
    {
        fr = applyFresnelOverlay(
            finalColor, albedo.w, NdotV_sat,
            psCB2.fresnelColor.xyz, fresnelAlphaMod, psCB2.fresnelTeamColor,
            input.vertColor.w);
    }

    // --- Cloak (standard or ML variant) ---
    if (psCB2.cloakAmount > 0)
    {
        if (TMat.hasMultiLayer)
        {
            CloakResult cr = applyCloakML(
                fr.color, fr.alpha, albedo.w,
                NdotV_sat, psCB2.cloakAmount, input.vertColor.w,
                blendWeight);
            return cr.colorAlpha;
        }
        else
        {
            CloakResult cr = applyCloak(
                fr.color, fr.alpha, albedo.w,
                NdotV_sat, psCB2.cloakAmount, input.vertColor.w);
            return cr.colorAlpha;
        }
    }
    return float4(fr.color, fr.alpha);
}
