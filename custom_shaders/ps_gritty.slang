// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Gritty pixel shader bodies. Parallels the three HD bodies in
// ps_ibl.slang / ps_standard.slang so the gritty entry point can dispatch
// with the same (HAS_IBL, TMat.hasMultiLayer) logic:
//
//   psGrittyIBLBody         — full Cook-Torrance + IBL path with shadow
//                              cascades, with desaturate / roughen /
//                              ambient-attenuate tweaks.
//   psGrittyMultiLayerBody  — cheap non-IBL path + team-color blend.
//   psGrittyStandardBody    — cheapest non-IBL path.
//
// Unlike toon, gritty stays inside the PBR model. The differences vs.
// HD live at three injection points:
//
//   1. After the albedo sample, before lighting: `grittyRecolor` pulls
//      strongly-saturated regions toward luminance gray (anti-cartoon),
//      with extra desaturation on dielectrics so painted props look
//      weathered while metals retain colored reflections.
//   2. After the ORM sample (IBL only): `grittyRoughen` pushes
//      `orm.x` toward 1.0 by a constant amount, which broadens specular
//      highlights and biases IBL specular toward higher mips.
//   3. After lighting: ambient/IBL diffuse contribution is attenuated
//      more than direct light so shadows go deeper, and a final
//      `grittyPostLight` applies a mild contrast lift around mid-gray.
//
// Everything downstream of lighting (fresnel overlay, cloak, emissive,
// per-vertex tint, color matrix, fog, MRT packing, debug visualisation)
// is shared with HD unchanged — the gritty look is orthogonal to the
// engine's selection / cloak / debug pipeline.

implementing custom_shaders;

// =====================================================================
// Gritty tunables
// =====================================================================

// Selective desaturation. The base term applies a flat pull toward
// luminance gray; the high-sat term adds extra desaturation on already-
// vivid colors (so the saturation cap reads as overcast/weathered); the
// dielectric term spares metals so colored reflections still pop. Tuned
// so a fully-saturated dielectric pixel only loses ~35% of its chroma —
// reds, golds, and team tints keep their identity but read muted.
static const float GRITTY_DESAT_BASE        = 0.05;
static const float GRITTY_DESAT_HIGH_SAT    = 0.20;
static const float GRITTY_DESAT_DIELECTRIC  = 0.10;

// Rough-dielectric extra pull (IBL body only — needs roughness +
// metalness + team blend weight to gate). Adds ~10% more desat on
// surfaces that are simultaneously rough, non-metal, and non-team-
// stamped — i.e. weathered painted/cloth areas. Metals, polished
// dielectrics, and team-color regions are spared.
static const float GRITTY_DESAT_ROUGH       = 0.10;

// Roughness lift. 0.0 = no change, 1.0 = pinned to fully rough. 0.35
// reads as worn paint / oxidised metal without flattening the highlight
// to nothing.
static const float GRITTY_ROUGHEN           = 0.35;

// Ambient/IBL-diffuse attenuation. Applied to the analytical+IBL ambient
// blend before it modulates the diffuse albedo. Kept close to 1.0 so
// doodads (which are mostly diffuse with little specular contribution)
// don't get crushed harder than lit characters — a uniform darkening
// across surface types reads better than a high-contrast ambient/spec
// split.
static const float GRITTY_AMBIENT_SCALE     = 0.92;

// Final pre-fresnel post-light grade. `DIRECT_SCALE` darkens the whole
// lit term modestly; `CONTRAST` lifts contrast around `MID` (≈ 0.18,
// the usual perceptual mid-gray pivot in linear space). Both are
// tuned for a gentle, uniform mood pass — most of the gritty character
// comes from desat + roughness + noise, not heavy darkening.
static const float GRITTY_DIRECT_SCALE      = 0.90;
static const float GRITTY_CONTRAST          = 1.05;
static const float GRITTY_MID               = 0.18;

// Roughness-modulated noise. Smooth surfaces (low roughness) stay clean;
// rough surfaces get a per-pixel grain that reads as worn paint, dust,
// or oxidation. STRENGTH is the ±multiplier at full roughness; TILE
// scales the UV before the hash, controlling grain frequency (higher =
// finer grain).
static const float GRITTY_NOISE_STRENGTH    = 0.95;
static const float GRITTY_NOISE_TILE        = 2048.0;

// Pull `albedo` toward its luminance proportional to its current
// saturation and (for non-metals) a flat dielectric bonus. Metals see
// only the base term so colored metals stay colored.
public float3 grittyRecolor(float3 albedo, float metalness)
{
    float lum = dot(albedo, float3(0.2126, 0.7152, 0.0722));
    float maxC = max(albedo.r, max(albedo.g, albedo.b));
    float minC = min(albedo.r, min(albedo.g, albedo.b));
    float sat = saturate(maxC - minC);
    float desat = GRITTY_DESAT_BASE
                + GRITTY_DESAT_HIGH_SAT * sat
                + GRITTY_DESAT_DIELECTRIC * (1.0 - metalness);
    desat = saturate(desat);
    return lerp(albedo, lum.xxx, desat);
}

// IBL-only recolor variant: same as grittyRecolor plus an extra pull on
// surfaces that are simultaneously rough, non-metal, and non-team — the
// classic "weathered painted dielectric" case where the gritty look
// reads strongest. Metals, polished dielectrics, and team-stamp regions
// (high blendWeight) are gated out so they keep their visual identity.
public float3 grittyRecolorRough(float3 albedo, float metalness, float roughness, float teamWeight)
{
    float lum = dot(albedo, float3(0.2126, 0.7152, 0.0722));
    float maxC = max(albedo.r, max(albedo.g, albedo.b));
    float minC = min(albedo.r, min(albedo.g, albedo.b));
    float sat = saturate(maxC - minC);
    float desat = GRITTY_DESAT_BASE
                + GRITTY_DESAT_HIGH_SAT * sat
                + GRITTY_DESAT_DIELECTRIC * (1.0 - metalness)
                + GRITTY_DESAT_ROUGH * roughness * (1.0 - metalness) * (1.0 - teamWeight);
    desat = saturate(desat);
    return lerp(albedo, lum.xxx, desat);
}

// Push roughness fractionally toward 1.0.
public float grittyRoughen(float r)
{
    return saturate(lerp(r, 1.0, GRITTY_ROUGHEN));
}

// Final lit-color grade: gentle global darken + contrast lift around
// linear mid-gray. Clamped above zero so the contrast subtract can't
// produce negatives that propagate into the fresnel/cloak combine.
public float3 grittyPostLight(float3 lit)
{
    lit *= GRITTY_DIRECT_SCALE;
    return max(float3(0, 0, 0), (lit - GRITTY_MID) * GRITTY_CONTRAST + GRITTY_MID);
}

// Cheap procedural hash → float in [0, 1). Interleaved-gradient style:
// no trig, no texture, just two FMAs and a frac. Stable per-UV so the
// grain stays locked to the surface.
public float grittyHash(float2 p)
{
    return frac(52.9829189 * frac(dot(p, float2(0.06711056, 0.00583715))));
}

// Apply roughness-modulated noise to a lit color. At roughness = 0 the
// modulation is a no-op (color * 1.0); at roughness = 1 it reaches the
// full ±GRITTY_NOISE_STRENGTH multiply window. Hash uses UV * TILE so
// the grain is texture-space (moves with the surface, not the camera).
public float3 grittyNoiseModulate(float3 color, float roughness, float2 uv)
{
    float n = grittyHash(uv * GRITTY_NOISE_TILE);
    float modulation = 1.0 + (n - 0.5) * 2.0 * roughness * GRITTY_NOISE_STRENGTH;
    return color * modulation;
}

// =====================================================================
// HD constants mirrored locally
// =====================================================================
// These values live as `static const` (file-private) inside
// wc3_shaders/effects/{cloak,multi_layer,fresnel_overlay}.slang and
// aren't visible from the custom_shaders module. We need them for the
// inlined fresnel/cloak math in psGrittyMultiLayerBody (which mirrors
// HD's psMultiLayerBody one-for-one), so we mirror the literals here
// rather than touching the wc3_shaders source.
static const float3 GRITTY_FRESNEL_TARGET   = float3(0, 0, 0.999000967);
static const float3 GRITTY_CLOAK_TINT       = float3(0.312999994, 0.853999972, 0.787999988);
static const float  GRITTY_CLOAK_ALPHA_BIAS = 0.200000003;
static const float  GRITTY_CLOAK_EDGE_SCALE = 0.5;
static const float  GRITTY_EDGE_DETECT_SCALE = 10.0;
static const float  GRITTY_ML_ALPHA_RAMP_SCALE = 0.199999988;
static const float  GRITTY_ML_ALPHA_RAMP_BIAS  = 0.5;
static const float  GRITTY_ML_EMISSIVE_BLEND   = 0.75;

// =====================================================================
// Full lit gritty body (IBL / directional / shadow cascades).
// =====================================================================
// Mirrors psIBLBody one-for-one. Only differences vs. HD are the four
// gritty injection points (recolor albedo, roughen orm.x, attenuate
// ambient blend, post-light grade) — everything else is bit-identical.
public float4 psGrittyIBLBody<
    TMat : IMaterialLayer,
    let HAS_EXTRA_VERTS : bool,
    let HAS_DEBUG_VIS : bool>(
    PSInput input, bool isFrontFace)
{
    float4 albedo = t_albedo.Sample(s_albedo, input.uv.xy);
    float3 normalSample = t_normal.Sample(s_normal, input.uv.xy).xyw;
    float3 ormFull = t_orm.Sample(s_orm, input.uv.xy).yzw;
    float2 orm = ormFull.xy;
    float3 emissive = t_emissive.Sample(s_emissive, input.uv.xy).xyz;

    if (HAS_DEBUG_VIS)
    {
        uint enabled = asuint(psCB3.enabledShaders);
        if ((enabled & 1u) != 0)
            albedo.xyz = psCB3.overrideAlbedo;
        if ((enabled & 2u) != 0)
            orm = psCB3.overrideOrm.yz;
    }

    float3 teamAlbedo = float3(0, 0, 0);
    float blendWeight = 0.0;
    float3 teamHueNorm = float3(0, 0, 0);
    float teamLuma = 0.0;

    if (TMat.hasMultiLayer)
    {
        blendWeight = ormFull.z;
        // Match HD's sample shape exactly — any deviation here (float4
        // capture, partial-swizzle write back, etc.) breaks the IBL+ML
        // perms even when the alpha is preserved. Team-color recolor
        // needs to happen via a different injection point.
        teamAlbedo = t_teamColor.Sample(s_teamColor, input.uv.xy).xyz;
        teamLuma = max(max(teamAlbedo.x, teamAlbedo.y), teamAlbedo.z);
        teamHueNorm = teamAlbedo / (teamLuma + SAFE_EPS);
    }

    // Gritty roughness lift. Done before the IBL/BRDF math so it
    // propagates into both Cook-Torrance and the IBL mip selection.
    float roughness = grittyRoughen(orm.x);
    float metalness = orm.y;

    if (TMat.hasMultiLayer)
    {
        // Compute desaturated team-color into a new local variable
        // here — far from the team-color sample, so we don't disturb
        // the sample's bytecode shape (see feedback memory). This
        // makes the team contribution that flows into multiLayerBlend
        // sit under the same gritty palette as the base albedo.
        float3 desatTeam = grittyRecolor(teamAlbedo, 0.0);
        MultiLayerResult ml = multiLayerBlend(albedo.xyz, desatTeam, blendWeight, emissive);
        albedo.xyz = ml.albedo;
        emissive = ml.emissive;
    }

    // Gritty recolor placed AFTER the multilayer blend so it's the only
    // partial-swizzle write to `albedo.xyz` for non-ML perms (and the
    // last one for ML perms). Uses the rough-aware variant so weathered
    // painted dielectrics get an extra ~10% pull on top of the base
    // recolor; metals, polished dielectrics, and team-stamped regions
    // stay protected.
    albedo.xyz = grittyRecolorRough(albedo.xyz, metalness, roughness, blendWeight);

    float shadowAtten = 1.0;
#if WC3_HAS_SHADOWS
    if (HAS_EXTRA_VERTS)
    {
        shadowAtten = sdSampleShadowCascades(
            input.shadowClip0, input.shadowClip1, input.shadowClip2,
            asuint(sdPsCB1.numCascades));
    }
#endif

    float3 tsNormal = decodeNormalMap(normalSample);
    float3 viewNormal = tangentToWorld(tsNormal, input.tangentWS.xyz, input.normalWS.xyz, input.tangentWS.w);
    viewNormal = orientNormal(viewNormal, isFrontFace);

    float roughnessMip = roughnessToMip(roughness);
    float roughnessAA = psCB2.useNdf != 0 ? specularAA(roughnessMip, viewNormal) : roughnessMip;

    float viewDirLen = rsqrt(dot(-input.worldPos.xyz, -input.worldPos.xyz));
    float3 viewDir = -input.worldPos.xyz * viewDirLen;

    float3 F0 = metalness * albedo.xyz;
    float3 diffuseAlbedo = (1.0 - metalness) * albedo.xyz;
    float3 lambertianDiffuse = INV_PI * diffuseAlbedo;

    float3 accum = float3(0, 0, 0);
    uint firstLightProcessed = 0;

    bool hasFirstLight = asuint(psCB2.lightCount) > 0;
    bool firstIsDirectional = hasFirstLight && (psCB2.lights[0].type == 0.0);

    if (firstIsDirectional)
    {
        float3 lightDir = psCB2.lights[0].position;

        float3 H = normalize(viewDir + lightDir);
        float VdotH = dot(H, viewDir);
        float NdotH = dot(viewNormal, H);
        float NdotL = dot(viewNormal, lightDir);
        float NdotV = dot(viewNormal, viewDir);

        float3 F = schlickFresnel(F0, VdotH);
        float D = ggxNDF(NdotH, roughnessAA);
        float V = schlickGGXVisibility(NdotL, NdotV, roughnessAA);
        float3 spec = D * F * V;
        float clampedNdotL = max(0.0, NdotL);

        float litNdotL = HAS_EXTRA_VERTS ? (clampedNdotL * shadowAtten) : clampedNdotL;

        IBLSampleResult ibl = sampleIBL(
            input.worldPos.xyz, viewNormal, roughnessAA,
            psCB2.view,
            psCB2.envFromMipEnd, psCB2.envToMipEnd, psCB2.envTransitionT);

        float maxDiffuse = max(max(psCB2.lights[0].diffuse.x, psCB2.lights[0].diffuse.y), psCB2.lights[0].diffuse.z);
        float ambientWeight = psCB2.lights[0]._pad2.x;

        float3 ambientResult = blizzardAmbientBlend(
            psCB2.lights[0].diffuse, ibl.diffuseIrradiance,
            litNdotL, maxDiffuse, ibl.isActive, ambientWeight);
        ambientResult += psCB2.lights[0].ambient;

        // Gritty: attenuate ambient/IBL-diffuse only — direct spec /
        // IBL spec stay full strength so highlights still read.
        ambientResult *= GRITTY_AMBIENT_SCALE;

        float totalWeight = maxDiffuse + ibl.isActive;
        float3 scaledSpec = spec * totalWeight * litNdotL;

        float3 indirectSpec = F0 * ibl.brdfLUT.x + ibl.brdfLUT.y;
        float ambientIBLWeight = totalWeight * ibl.isActive * ambientWeight;
        indirectSpec *= ambientIBLWeight;
        indirectSpec += scaledSpec * psCB2.lights[0].diffuse;
        indirectSpec *= ibl.specularRadiance;

        accum = ambientResult * lambertianDiffuse + indirectSpec;
        firstLightProcessed = 1;
    }

    float NdotV_precomp = dot(viewNormal, viewDir);
    float3 oneMinusF0 = 1.0 - F0;

    float3 loopResult = lightLoop(
        input.worldPos.xyz, viewNormal, viewDir, viewDirLen,
        F0, oneMinusF0, lambertianDiffuse,
        roughnessAA, NdotV_precomp,
        firstLightProcessed);
    accum += loopResult;

    float3 finalColor = PI * accum;
    finalColor += emissive * psCB2.emissiveGain;

    float3 linearVert = srgbToLinear(input.vertColor.xyz);
    finalColor *= linearVert;

    // Roughness-modulated noise. Applied before the post-light grade
    // so the contrast lift can amplify the grain slightly. Smooth
    // dielectrics / polished metals stay clean; rough surfaces get the
    // weathered grain. roughness here is post-grittyRoughen.
    finalColor = grittyNoiseModulate(finalColor, roughness, input.uv.xy);

    // Gritty post-light grade. Done before the fresnel overlay so the
    // selection rim / cloak tint stays at full intensity (those are UI
    // cues, not lighting — they shouldn't get dragged into shadow).
    finalColor = grittyPostLight(finalColor);

    float NdotV_sat = saturate(NdotV_precomp);
    float oneMinusNdotV = 1.0 - NdotV_sat;
    float fresnelSq = oneMinusNdotV * oneMinusNdotV;
    float fAlpha = psCB2.fresnelColor.w * fresnelSq;

    float3 fresnelResult;
    float finalAlpha;

    if (TMat.hasMultiLayer)
    {
        FresnelOverlayResult fr = applyFresnelOverlayML(
            finalColor, albedo.w, NdotV_sat,
            psCB2.fresnelColor.xyz, psCB2.fresnelColor.w, psCB2.fresnelTeamColor,
            input.vertColor.w,
            teamAlbedo, teamLuma);
        fresnelResult = fr.color;
        finalAlpha = fr.alpha;
    }
    else
    {
        FresnelOverlayResult fr = applyFresnelOverlay(
            finalColor, albedo.w, NdotV_sat,
            psCB2.fresnelColor.xyz, psCB2.fresnelColor.w, psCB2.fresnelTeamColor,
            input.vertColor.w);
        fresnelResult = fr.color;
        finalAlpha = fr.alpha;
    }

    bool cloakActive = psCB2.cloakAmount > 0;
    if (cloakActive)
    {
        if (TMat.hasMultiLayer)
        {
            CloakResult cr = applyCloakML(
                fresnelResult, finalAlpha, albedo.w,
                NdotV_sat, psCB2.cloakAmount, input.vertColor.w,
                blendWeight);
            return cr.colorAlpha;
        }
        else
        {
            CloakResult cr = applyCloak(
                fresnelResult, finalAlpha, albedo.w,
                NdotV_sat, psCB2.cloakAmount, input.vertColor.w);
            return cr.colorAlpha;
        }
    }

    return float4(fresnelResult, finalAlpha);
}

// =====================================================================
// Cheap single-layer gritty body (no IBL, no analytical lights).
// =====================================================================
// Mirrors HD's psStandardBody one-for-one, including the separate
// HAS_DEBUG_VIS / release branches and the release-path's inlined
// fresnel + cloak math. Gritty injections: `grittyRecolor` on the base
// albedo (full dielectric — matches the non-PBR origin) and
// `grittyPostLight` on the lit color before the fresnel inline.
public float4 psGrittyStandardBody<let HAS_DEBUG_VIS : bool>(PSInput input, bool isFrontFace)
{
    float4 albedo;
    float3 emissive;
    float3 normalSample;
    float3 worldNormal;
    float normalLen;

    if (HAS_DEBUG_VIS)
    {
        albedo = t_albedo.Sample(s_albedo, input.uv.xy);
        normalSample = t_normal.Sample(s_normal, input.uv.xy).xyw;
        emissive = t_emissive.Sample(s_emissive, input.uv.xy).xyz;

        if (asint(psCB3.enabledShaders) & 1)
            albedo.xyz = psCB3.overrideAlbedo;

        float3 recoloredAlbedo = grittyRecolor(albedo.xyz, 0.0);

        float3 tsNormal = decodeNormalMap(normalSample);
        worldNormal = tangentToWorld(tsNormal, input.tangentWS.xyz, input.normalWS.xyz, input.tangentWS.w);
        normalLen = length(worldNormal);
        worldNormal = normalize(worldNormal);
        worldNormal = orientNormal(worldNormal, isFrontFace);

        float3 litColor = emissive * psCB2.emissiveGain + recoloredAlbedo;
        float3 linearVert = srgbToLinear(input.vertColor.xyz);
        litColor *= linearVert;
        litColor = grittyPostLight(litColor);

        float3 viewDir = normalize(-input.worldPos.xyz);
        float NdotV = saturate(dot(viewDir, worldNormal));

        FresnelOverlayResult fr = applyFresnelOverlay(
            litColor, albedo.w, NdotV,
            psCB2.fresnelColor.xyz, psCB2.fresnelColor.w, psCB2.fresnelTeamColor,
            input.vertColor.w);

        bool cloakActive = psCB2.cloakAmount > 0;
        if (cloakActive)
        {
            CloakResult cr = applyCloak(
                fr.color, fr.alpha, albedo.w,
                NdotV, psCB2.cloakAmount, input.vertColor.w);
            return cr.colorAlpha;
        }
        return float4(fr.color, fr.alpha);
    }
    else
    {
        // Release path mirrors HD's release-path layout exactly: same
        // sample order, same inlined fresnel + cloak math. The only
        // gritty additions are the albedo recolor and the post-light
        // grade.
        normalSample = t_normal.Sample(s_normal, input.uv.xy).xyw;
        float3 tsNormal = decodeNormalMap(normalSample);
        worldNormal = tangentToWorld(tsNormal, input.tangentWS.xyz, input.normalWS.xyz, input.tangentWS.w);
        worldNormal = orientNormal(worldNormal, isFrontFace);

        float3 viewDir = normalize(-input.worldPos.xyz);
        float NdotV = saturate(dot(viewDir, worldNormal));
        float oneMinusNdotV = 1.0 - NdotV;
        float fresnelSq = oneMinusNdotV * oneMinusNdotV;

        float edgeMask = min(1.0, (1.0 - fresnelSq) * GRITTY_EDGE_DETECT_SCALE);
        float cloakAlpha = edgeMask * GRITTY_CLOAK_EDGE_SCALE + GRITTY_CLOAK_ALPHA_BIAS;
        cloakAlpha = psCB2.cloakAmount * (cloakAlpha - input.vertColor.w) + input.vertColor.w;

        float fresnelAlphaContrib = psCB2.fresnelColor.w * fresnelSq;
        float teamSq = psCB2.fresnelTeamColor * psCB2.fresnelTeamColor;
        float maxFresnel = max(max(psCB2.fresnelColor.x, psCB2.fresnelColor.y), psCB2.fresnelColor.z);
        float intensity = maxFresnel + teamSq * (min(1.0, maxFresnel) - maxFresnel);
        float safeMaxInv = 1.0 / (maxFresnel + SAFE_EPS);
        float3 normTint = psCB2.fresnelColor.xyz * safeMaxInv;
        float3 blendedTint = psCB2.fresnelTeamColor * (GRITTY_FRESNEL_TARGET - normTint) + normTint;

        float3 linearVert = srgbToLinear(input.vertColor.xyz);
        emissive = t_emissive.Sample(s_emissive, input.uv.xy).xyz;
        albedo = t_albedo.Sample(s_albedo, input.uv.xy);

        // Gritty albedo recolor (full dielectric for the non-PBR path).
        float3 recoloredAlbedo = grittyRecolor(albedo.xyz, 0.0);

        float3 litColor = (emissive * psCB2.emissiveGain + recoloredAlbedo) * linearVert;
        litColor = grittyPostLight(litColor);

        float3 fresnelColor = blendedTint * intensity;
        float3 finalColor = fresnelAlphaContrib * (fresnelColor - litColor) + litColor;
        float fresnelAlphaResult = fresnelAlphaContrib * albedo.w;
        float finalAlpha = saturate(input.vertColor.w * albedo.w + fresnelAlphaResult);

        bool cloakActive = psCB2.cloakAmount > 0;
        if (cloakActive)
        {
            float cloakedAlpha = albedo.w * cloakAlpha;
            float3 tinted = psCB2.cloakAmount * fresnelSq * (GRITTY_CLOAK_TINT - finalColor) + finalColor;
            return float4(tinted, cloakedAlpha);
        }
        return float4(finalColor, finalAlpha);
    }
}

// =====================================================================
// Cheap multi-layer gritty body (no IBL, no analytical lights).
// =====================================================================
// Same shape as the standard body. Both the base albedo and the team
// color stamp are desaturated so the entire surface reads under one
// gritty palette.
public float4 psGrittyMultiLayerBody<let HAS_DEBUG_VIS : bool>(PSInput input, bool isFrontFace)
{
    // Mirrors HD's psMultiLayerBody one-for-one — same separate
    // HAS_DEBUG_VIS / release branches, same sample order, same inlined
    // fresnel/cloak math. The only differences are the gritty
    // injections: `grittyRecolor` on the recolored albedo (kept in a
    // separate variable so we never write back via partial swizzle) and
    // `grittyPostLight` on litColor before the fresnel inline.
    float3 linearVert;
    float4 albedo;
    float3 teamAlbedo;
    float blendWeight;
    float3 emissive;
    float3 normalSample;

    if (HAS_DEBUG_VIS)
    {
        albedo = t_albedo.Sample(s_albedo, input.uv.xy);
        normalSample = t_normal.Sample(s_normal, input.uv.xy).xyw;
        blendWeight = t_orm.Sample(s_orm, input.uv.xy).w;
        emissive = t_emissive.Sample(s_emissive, input.uv.xy).xyz;
        teamAlbedo = t_teamColor.Sample(s_teamColor, input.uv.xy).xyz;

        if (asint(psCB3.enabledShaders) & 1)
            albedo.xyz = psCB3.overrideAlbedo;

        linearVert = srgbToLinear(input.vertColor.xyz);
    }
    else
    {
        linearVert = srgbToLinear(input.vertColor.xyz);
        albedo = t_albedo.Sample(s_albedo, input.uv.xy);
        teamAlbedo = t_teamColor.Sample(s_teamColor, input.uv.xy).xyz;
        blendWeight = t_orm.Sample(s_orm, input.uv.xy).w;
        emissive = t_emissive.Sample(s_emissive, input.uv.xy).xyz;
    }

    // Gritty albedo recolor stored in a separate variable so we never
    // partial-swizzle write to `albedo.xyz` after the function call.
    float3 recoloredAlbedo = grittyRecolor(albedo.xyz, 0.0);

    MultiLayerResult ml = multiLayerBlend(recoloredAlbedo, teamAlbedo, blendWeight, emissive);

    float3 litColor = (ml.emissive * psCB2.emissiveGain + ml.albedo) * linearVert;
    litColor = grittyPostLight(litColor);

    float teamLuma = max(max(teamAlbedo.x, teamAlbedo.y), teamAlbedo.z);
    float teamSafe = 1.0 / (teamLuma + SAFE_EPS);

    if (!HAS_DEBUG_VIS)
        normalSample = t_normal.Sample(s_normal, input.uv.xy).xyw;

    float3 tsNormal = decodeNormalMap(normalSample);
    float3 worldNormal = tangentToWorld(tsNormal, input.tangentWS.xyz, input.normalWS.xyz, input.tangentWS.w);
    worldNormal = orientNormal(worldNormal, isFrontFace);

    float3 viewDir = normalize(-input.worldPos.xyz);
    float NdotV = saturate(dot(viewDir, worldNormal));
    float oneMinusNdotV = 1.0 - NdotV;
    float fresnelSq = oneMinusNdotV * oneMinusNdotV;

    // Inlined applyFresnelOverlayML — mirrors HD ps_standard.slang:204-215.
    float fAlpha = psCB2.fresnelColor.w * fresnelSq;
    float maxFresnel = max(max(psCB2.fresnelColor.x, psCB2.fresnelColor.y), psCB2.fresnelColor.z);
    float safeMaxInv = 1.0 / (maxFresnel + SAFE_EPS);
    float3 normTint = psCB2.fresnelColor.xyz * safeMaxInv;
    float3 mlTintTarget = teamAlbedo * teamSafe;
    float3 blendedTint = psCB2.fresnelTeamColor * (mlTintTarget - normTint) + normTint;
    float teamSq = psCB2.fresnelTeamColor * psCB2.fresnelTeamColor;
    float intensity = maxFresnel + teamSq * (min(maxFresnel, teamLuma) - maxFresnel);
    float3 fresnelColor = blendedTint * intensity;

    float3 finalColor = fAlpha * (fresnelColor - litColor) + litColor;
    float finalAlpha = saturate(input.vertColor.w * albedo.w + fAlpha * albedo.w);

    bool cloakActive = psCB2.cloakAmount > 0;
    if (cloakActive)
    {
        // Inlined applyCloakML — mirrors HD ps_standard.slang:223-238.
        float edgeMask = min(1.0, (1.0 - fresnelSq) * GRITTY_EDGE_DETECT_SCALE);
        float alphaRamp = blendWeight * GRITTY_ML_ALPHA_RAMP_SCALE + GRITTY_ML_ALPHA_RAMP_BIAS;
        float cloakAlpha = edgeMask * alphaRamp + GRITTY_CLOAK_ALPHA_BIAS;
        cloakAlpha = psCB2.cloakAmount * (cloakAlpha - input.vertColor.w) + input.vertColor.w;
        float cloakedAlpha = albedo.w * cloakAlpha;

        float tintReduced = fresnelSq * blendWeight;
        tintReduced = tintReduced * -GRITTY_ML_EMISSIVE_BLEND + fresnelSq;
        float3 tinted = psCB2.cloakAmount * tintReduced * (GRITTY_CLOAK_TINT - finalColor) + finalColor;

        return float4(tinted, cloakedAlpha);
    }
    return float4(finalColor, finalAlpha);
}
