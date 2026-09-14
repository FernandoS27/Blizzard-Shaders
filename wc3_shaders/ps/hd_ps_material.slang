// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Material sampling, the normal chain and the fresnel / cloak finish for the
// 3.0.0 HD mesh pixel shader, plus the constants the shipped shader bakes in.
//
// The constants are spelled at the precision fxc printed them at rather than
// rounded, because several of them are load-bearing thresholds rather than
// tuning knobs — 0.999000967 is not 0.999, and a differential test notices.

implementing wc3_shaders;

// --- BRDF / shading ---------------------------------------------------------
public static const float HD_GGX_MIN_DENOM     = 1.00000001e-07;
public static const float HD_ROUGHNESS_SCALE   = 0.899999976;   // rough = tex*0.9 + 0.05
public static const float HD_ROUGHNESS_BIAS    = 0.0500000007;

// Split factors for the ambient / IBL mix: an "upper" term that dominates
// where the surface faces the light and a "lower" term that survives in shadow
// so unlit sides do not go flat.
public static const float HD_IBL_SPLIT_UPPER   = 0.675000012;
public static const float HD_IBL_SPLIT_LOWER   = 0.324999988;

// --- Fresnel rim, cloak, team layer ----------------------------------------
public static const float3 HD_FRESNEL_TARGET   = float3(0, 0, 0.999000967);
public static const float3 HD_CLOAK_TINT       = float3(0.400000006, 0.400000006, 0.400000006);
public static const float  HD_CLOAK_ALPHA_BIAS = 0.200000003;
public static const float  HD_CLOAK_EDGE_SCALE = 0.5;
public static const float  HD_EDGE_DETECT_SCALE = 10;
public static const float  HD_ML_ALPHA_RAMP_SCALE = 0.199999988;
public static const float  HD_ML_ALPHA_RAMP_BIAS  = 0.5;
public static const float  HD_ML_TINT_FALLOFF     = -0.75;
public static const float  HD_ML_BLEND_SMOOTH     = 0.949999988;

// --- Shadows ----------------------------------------------------------------
// Below this the first cascade set has already shadowed the pixel so thoroughly
// that evaluating the second one cannot change the result.
public static const float HD_CASCADE_EARLY_OUT = 0.00400000019;
// PCF step for the cube shadows, in normalised cube space: 1/256.
public static const float HD_CUBE_PCF_STEP     = 0.00390625;

// --- Light-complexity / shadow-range debug overlay --------------------------
// The engine marks "this light is an editor gizmo, not a light" by giving it a
// radiance magnitude inside a specific 1/255 bracket — the brackets below are
// therefore exact, not approximate.
public static const float HD_DBG_MIN_RADIANCE      = 0.00392156886;  // 1/255
public static const float HD_DBG_FULLBRIGHT_MAX    = 0.00470588217;  // 1.2/255
public static const float HD_DBG_HILIGHT_MIN       = 0.00588235306;  // 1.5/255
public static const float HD_DBG_HILIGHT_MAX       = 0.00784313772;  // 2/255
public static const float HD_DBG_STRIPE_FREQ       = 0.0666666701;
public static const float HD_DBG_STRIPE_DUTY       = 0.166666672;
public static const float HD_DBG_LIGHT_COUNT_SCALE = 0.00999999978;

// --- Deferred targets -------------------------------------------------------
public static const float HD_MRT_SOFTNESS_FACTOR = 0.75;
public static const float HD_NORMAL_PACK         = 0.5;

// ---------------------------------------------------------------------------
// Normal map
// ---------------------------------------------------------------------------

// Decode the normal map, scale its tangent-space XY by the per-draw strength,
// renormalise, and RE-ENCODE back into the [0,1] pair the rest of the shader
// works from.
//
// The round trip is the engine's, and it is not lossless: only `.x` is clamped
// on the way out, so a strength above 1 can push `.y` outside [0,1] and the
// second decode reads it back as an out-of-range Y. Reproducing the asymmetry
// matters — clamping both lanes changes the shading on every strong normal map.
public float2 encodeScaledNormal(float3 normalSample, float strength)
{
    float3 n = decodeNormalMap(normalSample);
    float2 xy = strength * n.xy;
    float3 scaled = float3(xy, n.z);
    xy = xy * rsqrt(dot(scaled, scaled));
    float2 enc = xy * float2(0.5, -0.5) + float2(0.5, 0.5);
    enc.x = saturate(enc.x);
    return enc;
}

// The re-encoded pair, decoded again. `decodeNormalMap` multiplies .x by .z
// before the bias to recover the R*A-packed X channel, so handing it a .z of
// one turns that product back into a plain `2x - 1` — which is exactly what
// the shipped shader's second decode does.
public float3 decodeEncodedNormal(float2 enc)
{
    return decodeNormalMap(float3(enc, 1.0));
}

// Tangent-space normal to world space, flipped for back faces.
public float3 hdWorldNormal(HDPSInput input, float2 enc, bool isFrontFace)
{
    float3 tsN = decodeEncodedNormal(enc);
    float3 n = tangentToWorld(tsN, input.tangentWS.xyz, input.normalWS,
                              input.tangentWS.w);
    return orientNormal(n, isFrontFace);
}

// ---------------------------------------------------------------------------
// Manual depth test
// ---------------------------------------------------------------------------

// The engine's software depth pre-resolve, run before any shading work.
//
// A zero in the depth target means "nothing has been drawn here", so only a
// POSITIVE sample can reject — without that guard the first object drawn into
// an empty target would cull itself everywhere.
public void hdDepthTestDiscard(float2 svPositionXY, float viewZ)
{
    if (0.5 < hdPsCB2.depthTestEnable)
    {
        float sceneDepth = t_hdSceneDepth.Load(int3(int2(svPositionXY), 0)).x;
        if ((0 < sceneDepth) && (viewZ - sceneDepth < 0))
            discard;
    }
}

// ---------------------------------------------------------------------------
// Material
// ---------------------------------------------------------------------------

// Everything the shading stack needs out of the five material maps. The team
// terms are carried past the blend because the fresnel rim re-uses them: with
// a team-colour layer the rim tints toward the team colour instead of the
// fixed blue bias.
public struct HDMaterial
{
    public float4 albedo;       // .w is the authored opacity
    public float3 emissive;
    public float2 roughMetal;   // t2.yz, LIGHTING only
    public float3 teamRGB;
    public float  teamWeight;
    public float  maxTeam;      // largest component of teamRGB
    public float  invTeam;      // 1 / (eps + maxTeam)
};

// Sample the material set and, for a team-coloured material, fold the team
// layer into albedo and emissive.
//
// The blend is hue-preserving: both albedos are divided by their own largest
// component before mixing, and the luminance is restored afterwards from the
// two maxima. Mixing the raw colours instead would let a bright team colour
// wash out the base material's shading.
public HDMaterial sampleHDMaterial<TMat : IMaterialLayer, let HAS_LIGHTING : bool>(float2 uv)
{
    return sampleHDMaterialFrom<TMat, HAS_LIGHTING>(uv, t_hdAlbedo.Sample(s_hdAlbedo, uv));
}

// The same, over a base albedo the caller has already produced.
//
// This exists for `crystal_ps`, whose albedo is a blend of two taps of the same
// map rather than one, and which feeds the BLENDED colour into the team layer
// -- confirmed in the shipped bytecode, where the refraction lerp lands before
// the hue-preserving mix and the mix's `maxBase` is taken over the blended
// value. Splitting the function rather than copying it keeps one implementation
// of a blend that four constants and an order of operations have to match.
public HDMaterial sampleHDMaterialFrom<TMat : IMaterialLayer, let HAS_LIGHTING : bool>(
    float2 uv, float4 baseAlbedo)
{
    HDMaterial m;
    m.albedo     = baseAlbedo;
    m.emissive   = t_hdEmissive.Sample(s_hdEmissive, uv).xyz;
    m.roughMetal = HAS_LIGHTING ? t_hdOrm.Sample(s_hdOrm, uv).yz : float2(0, 0);
    m.teamRGB    = float3(0, 0, 0);
    m.teamWeight = 0;
    m.maxTeam    = 0;
    m.invTeam    = 0;

    if (TMat.hasMultiLayer)
    {
        m.teamWeight = t_hdOrm.Sample(s_hdOrm, uv).w;
        m.teamRGB    = t_hdTeamColor.Sample(s_hdTeamColor, uv).xyz;
        m.maxTeam    = max(max(m.teamRGB.y, m.teamRGB.z), m.teamRGB.x);
        m.invTeam    = 1.0 / (SAFE_EPS + m.maxTeam);

        // `1 / rsqrt(w)` rather than `sqrt(w)` is the shipped form; it agrees
        // with sqrt everywhere including w == 0 (rsqrt gives inf, the
        // reciprocal gives zero back).
        float sqrtW   = 1.0 / rsqrt(m.teamWeight);
        float smoothW = HD_ML_BLEND_SMOOTH * (m.teamWeight * m.teamWeight);
        float maxBase = max(max(m.albedo.y, m.albedo.z), m.albedo.x);
        float3 baseN  = m.albedo.xyz * (1.0 / (SAFE_EPS + maxBase));

        m.albedo.xyz = sqrtW * (m.teamRGB * m.invTeam - baseN) + baseN;
        float lum = smoothW * (min(m.maxTeam, maxBase) - maxBase) + maxBase;
        m.albedo.xyz = m.albedo.xyz * lum;

        m.emissive = m.teamWeight * (m.emissive * m.teamRGB - m.emissive) + m.emissive;
    }
    return m;
}

// ---------------------------------------------------------------------------
// Fresnel rim, cloak and the final alpha
// ---------------------------------------------------------------------------

// Apply the rim overlay and the cloak ramp, and produce the alpha that goes
// with whichever of the two won.
//
// The cloak is a whole alternative surface, not a modifier: when it is on, the
// colour is the lit result pushed toward a flat grey by the rim, and the alpha
// comes from an edge-detect ramp instead of the material's own opacity. The
// shipped shader evaluates both and selects, which is what this mirrors.
public float4 hdFresnelAndCloak<TMat : IMaterialLayer>(
    float3 shadedRGB, float ndv, HDMaterial m, float vertAlpha)
{
    return hdFresnelAndCloakA<TMat>(shadedRGB, ndv, m, vertAlpha,
                                    hdPsCB2.fresnelColor.w);
}

// The same, over a rim-alpha parameter the caller supplies.
//
// `crystal_ps` is the only family that passes anything but the per-draw
// `fresnelColor.w`: it remaps the parameter by the refract mask so a fully
// transparent facet still takes a visible rim. The substitution happens at the
// PARAMETER, before the `(1 - NdotV)^2` weighting -- and it therefore also
// reaches `plainAlpha`, which is built from the same weighted value. Both of
// those are load-bearing; see effects/crystal_refract.slang.
public float4 hdFresnelAndCloakA<TMat : IMaterialLayer>(
    float3 shadedRGB, float ndv, HDMaterial m, float vertAlpha, float fresnelAlpha)
{
    float rim  = 1.0 - ndv;
    float rim2 = rim * rim;
    float fresnelA = fresnelAlpha * rim2;
    float teamF2 = hdPsCB2.fresnelTeamColor * hdPsCB2.fresnelTeamColor;

    float maxF = max(hdPsCB2.fresnelColor.x,
                     max(hdPsCB2.fresnelColor.y, hdPsCB2.fresnelColor.z));
    float invF = 1.0 / (SAFE_EPS + maxF);
    float3 fresnelN = hdPsCB2.fresnelColor.xyz * invF;

    // With a team layer the rim aims at the team colour and is clamped against
    // it too; without one it aims at the fixed blue bias.
    float3 fresnelTarget;
    float  fresnelClamp;
    if (TMat.hasMultiLayer)
    {
        fresnelTarget = m.teamRGB * m.invTeam;
        fresnelClamp  = min(maxF, m.maxTeam);
    }
    else
    {
        fresnelTarget = HD_FRESNEL_TARGET;
        fresnelClamp  = min(1.0, maxF);
    }

    float3 fresnelCol = hdPsCB2.fresnelTeamColor * (fresnelTarget - fresnelN) + fresnelN;
    float  fresnelInt = teamF2 * (fresnelClamp - maxF) + maxF;

    float3 plainRGB = fresnelA * (fresnelCol * fresnelInt - shadedRGB) + shadedRGB;
    float  plainAlpha = saturate(vertAlpha * m.albedo.w + fresnelA * m.albedo.w);

    // Cloak. `edge` peaks where the surface faces the camera edge-on, which is
    // what makes a cloaked unit read as a silhouette rather than a ghost.
    float edge = min(1.0, HD_EDGE_DETECT_SCALE * (-rim * rim + 1.0));
    float ramp = TMat.hasMultiLayer
               ? (m.teamWeight * HD_ML_ALPHA_RAMP_SCALE + HD_ML_ALPHA_RAMP_BIAS)
               : HD_CLOAK_EDGE_SCALE;
    float cloakAlpha = edge * ramp + HD_CLOAK_ALPHA_BIAS;
    cloakAlpha = hdPsCB2.cloakAmount * (cloakAlpha - vertAlpha) + vertAlpha;
    cloakAlpha = m.albedo.w * cloakAlpha;

    float tintT = TMat.hasMultiLayer
                ? ((rim2 * m.teamWeight) * HD_ML_TINT_FALLOFF + rim2)
                : rim2;
    float3 cloakRGB = hdPsCB2.cloakAmount * ((HD_CLOAK_TINT - plainRGB) * tintT) + plainRGB;

    return (0 < hdPsCB2.cloakAmount) ? float4(cloakRGB, cloakAlpha)
                                     : float4(plainRGB, plainAlpha);
}
