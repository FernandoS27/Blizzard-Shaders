// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// PopcornFX pixel-shader body + popcorn-specific helpers.
//
// The body is split into two top-level entry helpers:
//
//   • `popcornMotionPassBody`  — encodes 2D screen-space motion
//                                vectors into RT0.xy. Used by the
//                                MOTION_PASS specialization; depth-
//                                discards behind the opaque scene
//                                and (with VC) tints the motion by
//                                vertex-colour .xy + forwards .w
//                                into the output alpha.
//   • `popcornColorPassBody`   — full lit / diffuse / fog / alpha-LUT
//                                / soft-particles surface shading
//                                returned as an `(rgba, gbufferAlpha)`
//                                pair so the entry can route the
//                                gbuffer-alpha to RT2 separately.
//
// Helpers that aren't reused outside the popcorn pipeline are kept
// file-local (non-`public`). Helpers that map cleanly onto an
// existing wc3_shaders building block (`decodeNormalMap`,
// `tangentToWorld`, `orientNormal`, `specularAA`) are called through
// directly rather than re-implemented.
//
// ---------------------------------------------------------------------------
// What 3.0.0 changed in this file
// ---------------------------------------------------------------------------
//
// The COLOR pass was rewritten onto the HD pipeline's shared machinery; the
// MOTION pass was not touched at all beyond constant-buffer renumbering.
//
//  * The eight per-draw analytical lights are gone. Lighting is the same
//    clustered-forward walk `hd_ps` does — same cluster grid, same packed
//    16-bit index list, same 40-byte light records — so it calls
//    `hdClusterLights` rather than owning a copy. Popcorn instantiates it with
//    both feature flags off: this family has no shadow axis (no cube array, no
//    comparison sampler, nothing read from cb1[0..36]) and no debug overlay.
//
//  * The IBL block is `sampleHDIBL`, unchanged. The probes moved from
//    t13/t14/t15 to t11/t12/t13, which is where HD's already were.
//
//  * Fog became the runtime seven-mode dispatch plus the eleven-case blend
//    switch — `hdFogFactor` and `hdBlendModeFog`. The `TFog` permutation axis
//    is gone from the family entirely, and with it two of the seven inner bits.
//
//  * A world position arrives at TEXCOORD8 because the volumetric fog arm needs
//    one; TEXCOORD7 was, and still is, a VIEW position.
//
// What popcorn does NOT share is the main directional light. Its ambient / IBL
// mix is exactly HD's with `shadowedNdl` pinned to zero — see
// `popcornAmbientIBL` — because there is no sun term in the particle pipeline
// at all: `mainLightDir` is read only to orient the probe.

implementing wc3_shaders;

// ============================================================
// Named constants
// ============================================================

// Motion-vector encoding offsets. The engine packs each motion
// component as `(motion + 1.00391996) / 2`, so unpacking is
// `motion = sample · 2 − 1.00391996` (note the asymmetric
// −1.00391996 / +0.99608, matching an 8-bit signed roundtrip).
static const float MOTION_UNPACK_BIAS  = -1.00391996;

// Motion-vector magnitude scale: the source LUT stores motion in
// "world units per second at one metre depth", and the runtime
// rescales by sqrt(1000 / depth) so the projected screen-space
// magnitude stays roughly constant.
static const float MOTION_DEPTH_NUMER  = 1000.0;

// Default per-particle deferred material payload — neutral diffuse
// tint + 0.5 roughness/metallic-like values matching the shipped
// engine's deferred resolve assumptions.
static const float3 GBUFFER_DEFAULT_MAT = float3(1.0, 0.5, 0.5);

// ============================================================
// Per-mode UV resolution
// ============================================================

// Resolves the (single) sample UV for the per-mode diffuse / motion
// fetch, plus the second atlas UV when applicable. The two outputs
// pack a struct so a single helper covers all three live modes
// (basic / billboard / atlas) and the entry doesn't have to know the
// per-mode UV decoding rules.
public struct PopcornUV
{
    public float2 sampleUV;     // primary sample point
    public float2 sampleUV2;    // secondary (ATLAS only — second frame)
};

// Each particle is rendered as two triangles sharing the same atlas
// cell, with the quad UV (0,0)/(0,1)/(1,0)/(1,1) coming from the VS's
// SV_VertexID derivation. The two triangles map mirrored portions of
// the atlas cell, so we pick the half by `uv.x + uv.y < 1` and
// remap into the per-cell scale/bias from `slot1` (TEXCOORD1).
float2 popcornBillboardUV(float2 quadUV, float4 uvScaleBias, float4 uvAxisScales)
{
    float2 mirrored = (1.0 - quadUV) / uvAxisScales.zw;
    mirrored        = 1.0 - mirrored;
    float2 direct   = quadUV / uvAxisScales.xy;
    bool   firstTri = (quadUV.x + quadUV.y) < 1.0;
    float2 sampleUV = firstTri ? direct : mirrored;
    return sampleUV * uvScaleBias.xy + uvScaleBias.zw;
}

public PopcornUV popcornResolveUV<TMode : IPopcornMode>(PopcornPSInput input)
{
    PopcornUV uv;
    uv.sampleUV  = float2(0, 0);
    uv.sampleUV2 = float2(0, 0);
#if POPCORN_BILLBOARD
    uv.sampleUV = popcornBillboardUV(input.uv.xy, input.slot1, input.uvAxis);
#elif POPCORN_ATLAS
    uv.sampleUV  = input.uv.xy;
    uv.sampleUV2 = input.uv.zw;
#elif POPCORN_HAS_UV
    // Basic UV mode: straight pass-through of TEXCOORD0.xy.
    uv.sampleUV = input.uv.xy;
#endif
    return uv;
}

// ============================================================
// Soft-particles depth fade
// ============================================================

// cb2[22].x, under its popcorn meaning.
//
// `HDPSPerDraw` names this slot `outputAlphaScale` because that is what the HD
// mesh shader reads out of it. The engine fills the per-draw bank differently
// per pipeline, and for particles the same float is the soft-particle depth-fade
// scale — a different number with a different unit. Read through this so the
// call sites below say what they mean.
static float popcornDepthFadeScale() { return hdPsCB2.outputAlphaScale; }


// Project the VIEW position to clip space, normalise to the depth target's
// texel, sample it, and return `sceneZ - viewZ`.
//
// The caller turns that into a saturated fade, or — in the motion pass — uses
// it both for the discard test and as the motion multiplier.
//
// The v-flip and the remap are the engine's: the depth target is not
// necessarily the same size or orientation as the render target, so the NDC
// point goes through a scale/bias before it is a texel. Unchanged from 2.0.0
// apart from where the two constants live: cb2[11..14] -> cb2[16..19] and
// cb2[15] -> cb2[21].
public float popcornSceneDepthDelta(float3 viewPos)
{
    float3 clip = viewPos.x * hdPsCB2.viewToClip[0].xyw
                + viewPos.y * hdPsCB2.viewToClip[1].xyw
                + viewPos.z * hdPsCB2.viewToClip[2].xyw
                +             hdPsCB2.viewToClip[3].xyw;
    float2 ndc      = clip.xy / clip.z;
    ndc             = ndc * 0.5 + 0.5;
    float2 depthUV  = float2(ndc.x, 1.0 - ndc.y);
    depthUV         = hdPsCB2.depthUVRemap.xy * depthUV
                    + hdPsCB2.depthUVRemap.zw;
    float  sceneZ   = t_popcornDepth.Sample(s_popcornDepth, depthUV).x;
    return sceneZ - viewPos.z;
}

// ============================================================
// LIT path
// ============================================================

// Ambient + image-based lighting.
//
// This is `hdMainLight` with `shadowedNdl` pinned to zero, and it is worth
// being precise about why rather than calling it "similar". HD splits its
// ambient into an upper term that dominates where the surface faces the sun and
// a lower term that survives in shadow, then interpolates between them by
// `max(0, N.L) * shadow`. A particle has no sun: `mainLightDir` is read here
// only to build the probe's basis, and nothing in any of the 96 shipped LIT
// permutations computes an N.L against it. Substitute `shadowedNdl = 0` into
// HD's expression and the upper term drops out, the direct specular drops out,
// and what is left is exactly the sequence below — including the constant,
// which is `HD_IBL_SPLIT_LOWER` and not a separate 0.325 that happens to match.
//
// The probe sampling itself is `sampleHDIBL`, shared verbatim: same two cube
// arrays, same light-oriented basis, same mip ends, same split-sum LUT.
static float3 popcornAmbientIBL(HDSurface s, float3 viewPos)
{
    HDIBLSample ibl = sampleHDIBL(viewPos, s);

    float3 ambientColor = hdPsCB2.ambientColor.xyz;
    float maxAmb = max(ambientColor.x, max(ambientColor.y, ambientColor.z));
    float invAmb = 1.0 / (SAFE_EPS + maxAmb);
    float ambPlusIbl = maxAmb + ibl.weight;
    float iblScale = hdPsCB2.ambientAdd.w * (ambPlusIbl * ibl.weight);

    // Hue-separate the probe irradiance and the analytical ambient before
    // mixing, so the blend preserves saturation instead of washing out.
    float maxIrr = max(ibl.irradiance.x, max(ibl.irradiance.y, ibl.irradiance.z));
    float3 irrN = ibl.irradiance * (1.0 / (SAFE_EPS + maxIrr));
    float3 ambDelta = ambientColor * invAmb - irrN;

    float3 ambient = ambDelta * HD_IBL_SPLIT_LOWER + irrN;
    ambient = ambient * maxIrr;
    ambient = ambient * iblScale + hdPsCB2.ambientAdd.xyz;

    float3 iblSpec = (s.F0 * ibl.brdf.x + ibl.brdf.y) * iblScale;
    return ambient * s.diffColor + iblSpec * ibl.radiance;
}

// Whole-LIT-pipeline body — normal map decode, tangent-space basis
// reconstruction, specular-AA roughness, the ambient / IBL term and the
// clustered light walk. Returns the linear-RGB lit colour; the entry pairs it
// with the alpha the LUT and the vertex colour already settled.
//
// Only emitted when `POPCORN_HAS_NT` is set (i.e. the PS perm has the
// HAS_LIT bit and the engine pairs it with a VS perm that wrote
// normalWS/tangentWS). All call sites are wrapped in the same `#if`.
#if POPCORN_HAS_NT
public float3 popcornLitBody(PopcornPSInput input, PopcornUV uv,
                             bool isFrontFace, float3 albedoRGB,
                             out float3 shadedNormal)
{
    // Tangent-space normal from the packed map. With no UV stream the maps are
    // still bound and sampled at (0, 0) — effectively a one-texel "constant
    // material" mode, and that literal is what the shipped NoUV+LIT blobs
    // sample at too.
    float2 litMapUV     = uv.sampleUV;
    float3 normalSample = t_popcornNormal   .Sample(s_popcornNormal,    litMapUV).xyw;
    float2 roughMetal   = t_popcornSmoothMet.Sample(s_popcornSmoothMet, litMapUV).yz;

    float3 tsNormal = decodeNormalMap(normalSample);
    float3 N        = tangentToWorld(tsNormal, input.tangentWS.xyz,
                                     input.normalWS, input.tangentWS.w);
    N               = orientNormal(N, isFrontFace);
    shadedNormal    = N;   // forwarded to the deferred g-buffer (RT2.xyz)

    HDSurface surf;
    surf.N = N;
    surf.V = normalize(-input.viewPos);
    surf.albedo = albedoRGB;
    surf.metal = roughMetal.y;
    surf.F0 = surf.metal * albedoRGB;
    surf.diffColor = (albedoRGB - surf.metal * albedoRGB) * INV_PI;

    // Unlike HD, the authored roughness is used RAW: no 0.9 scale, no 0.05
    // bias. Particles are authored against the value the map stores.
    surf.rough = (asuint(hdPsCB2.useNdf) != 0) ? specularAA(roughMetal.x, N)
                                               : roughMetal.x;
    float rr = surf.rough * surf.rough;
    surf.a2 = rr * rr;
    float kSq = (1 + surf.rough) * (1 + surf.rough);
    surf.kDirect = SCHLICK_K_FACTOR * kSq;
    surf.kInv = -kSq * SCHLICK_K_FACTOR + 1;

    // Same switch HD has: the draw can turn the ambient / probe term off and
    // keep the cluster lights.
    float3 lit = float3(0, 0, 0);
    if (asint(hdPsCB2.mainLightEnable) != 0)
        lit = popcornAmbientIBL(surf, input.viewPos);

    // No shadows and no debug overlay in this family — see the file header.
    lit = hdClusterLights<false, false>(
        surf, input.viewPos, input.worldPos, input.svPosition.xy, lit);

    // Undo the 1/PI the Lambertian diffuse carried through the lights.
    return PI * lit;
}
#endif // POPCORN_HAS_NT

// ============================================================
// Color pass body
// ============================================================

// Composite return value so the entry can route the gbuffer alpha
// (= post-VC, post-LUT, pre-SP-fade alpha) to RT2 separately from
// the SP-faded RT0 alpha.
public struct PopcornColorOut
{
    public float4 color;            // RT0 — final RGBA
    public float  gbufferAlpha;     // RT2.w — pre-SP / pre-fog alpha
    public float3 gbufferMat;       // RT2.xyz — encoded world normal (LIT) or default material
};

// `TFog` is gone from this signature: 3.0.0 deleted the two fog bits from the
// family's permutation mask and selects all seven modes at runtime instead.
public PopcornColorOut popcornColorPassBody<
    TMode  : IPopcornMode,
    let HAS_VC        : bool,
    let HAS_ALPHA_LUT : bool,
    let HAS_SP        : bool,
    let HAS_LIT       : bool>(PopcornPSInput input, bool isFrontFace)
{
    // ---- Resolve UV + sample diffuse ----
    PopcornUV uv = popcornResolveUV<TMode>(input);

    float4 albedo;
#if POPCORN_ATLAS
    // Atlas: lerp between current and next frame by the life-
    // ratio fractional part the VS stored at slot1.x.
    {
        float4 a = t_popcornDiffuse.Sample(s_popcornDiffuse, uv.sampleUV);
        float4 b = t_popcornDiffuse.Sample(s_popcornDiffuse, uv.sampleUV2);
        albedo = lerp(a, b, input.slot1.x);
    }
#elif POPCORN_HAS_UV
    albedo = t_popcornDiffuse.Sample(s_popcornDiffuse, uv.sampleUV);
#else
    albedo = float4(1, 1, 1, 1);
#endif

    // ---- Vertex colour modulation ----
#if POPCORN_HAS_VC
    if (HAS_VC)
        albedo *= input.vertColor;
#endif

    // ---- Alpha LUT remap ----
    // The LUT input is the post-VC alpha; the result replaces alpha
    // and feeds every downstream consumer (LIT alpha source, SP
    // fade, gbuffer write, fog). Only the perms where the engine
    // actually binds ATTR6 (HAS_RANDOM && hasUV on the VS side) carry
    // the random slot; this PS-side `#if` matches that so phantom
    // TEXCOORD3 inputs don't leak into d3d12's PSO validation.
#if POPCORN_HAS_RANDOM_UV
    if (HAS_ALPHA_LUT && TMode.hasUV)
    {
        albedo.w = t_popcornAlphaLut.Sample(
            s_popcornAlphaLut, float2(albedo.w, input.random)).x;
    }
#endif

    // ---- Lighting ----
    // The deferred g-buffer (RT2.xyz) carries the encoded world normal for
    // lit particles and a flat default-material slot otherwise — matching
    // the retail `mad o2.xyz, worldN, 0.5, 0.5` vs constant write.
    float3 colorRGB;
    float3 gbufferMat = GBUFFER_DEFAULT_MAT;
#if POPCORN_HAS_NT
    if (HAS_LIT)
    {
        float3 shadedN;
        colorRGB   = popcornLitBody(input, uv, isFrontFace, albedo.xyz, shadedN);
        gbufferMat = shadedN * 0.5 + 0.5;
    }
    else
#endif
        colorRGB = albedo.xyz;

    float colorAlpha = albedo.w;

    // ---- Capture pre-SP alpha for the gbuffer write ----
    float gbufferAlpha = colorAlpha;

    // ---- Soft-particles fade (multiplies BOTH RGB and alpha,
    //      matching the engine's premultiplied-alpha pattern). ----
    if (HAS_SP)
    {
        float fade = saturate(popcornDepthFadeScale()
                              * popcornSceneDepthDelta(input.viewPos));
        colorRGB   *= fade;
        colorAlpha *= fade;
    }

    // ---- Fog ----
    // The seven-mode runtime dispatch and the blend-mode-aware application, both
    // shared with the HD pipeline. Note what the blend switch means here: it is
    // the reason the fade target is not always the fog colour, and it is also
    // why the alpha survives every case but the premultiplied one.
    //
    // No colour grade and no output alpha scale — `hdBlendModeFog` rather than
    // `hdApplyFogGraded`. The particle pipeline has neither.
    float fogFactor = hdFogFactor(input.viewPos.z, input.worldPos);

    PopcornColorOut out_;
    out_.color        = hdBlendModeFog(float4(colorRGB, colorAlpha), fogFactor);
    out_.gbufferAlpha = gbufferAlpha;
    out_.gbufferMat   = gbufferMat;
    return out_;
}

// ============================================================
// Motion-vector pass body
// ============================================================

// In MOTION_PASS the same UV resolution drives the t0 sample, but
// the .xy lanes of the texel are interpreted as a packed motion
// vector (2 × 8-bit unsigned, biased by ~−1.0039). The ALPHA_LUT,
// FOG, GBUFFER and LIT bits are dead in this pass — the engine
// keeps them on only so the input signature stays aligned across
// pass switches. SP and VC are the only flags with a functional
// effect here.
public float4 popcornMotionPassBody<
    TMode  : IPopcornMode,
    let HAS_VC : bool,
    let HAS_SP : bool>(PopcornPSInput input)
{
    PopcornUV uv = popcornResolveUV<TMode>(input);

    // Depth re-projection + scene-depth fetch. Pre-compute the soft
    // fade scalar BEFORE the discard so SP perms can still scale by
    // it (the discard saturates depthDelta < 0 to 0 anyway).
    float depthDelta = popcornSceneDepthDelta(input.viewPos);
    float softFade   = HAS_SP
                     ? saturate(popcornDepthFadeScale() * depthDelta)
                     : 1.0;
    if (depthDelta < 0.0) discard;

    // Motion source. Atlas mode lerps two t0 samples; basic /
    // billboard just sample the resolved UV. Only .xy is used.
    float2 motSrc;
#if POPCORN_ATLAS
    {
        float2 a = t_popcornDiffuse.Sample(s_popcornDiffuse, uv.sampleUV ).xy;
        float2 b = t_popcornDiffuse.Sample(s_popcornDiffuse, uv.sampleUV2).xy;
        motSrc = lerp(a, b, input.slot1.x);
    }
#else
    motSrc = t_popcornDiffuse.Sample(s_popcornDiffuse, uv.sampleUV).xy;
#endif

    // Unpack [0, 1] → ~[−1, +1], scale by sqrt(1000 / depth) so
    // screen-space magnitude stays roughly stable as particles
    // recede from the camera.
    float2 motion = motSrc * 2.0 + MOTION_UNPACK_BIAS;
    motion       *= sqrt(MOTION_DEPTH_NUMER / input.viewPos.z);

    // VERTEX_COLOR is the only "color" feature that meaningfully
    // affects MOTION_PASS — it tints the motion vectors by vc.xy
    // and forwards vc.w into the output alpha. Without VC the
    // alpha is the constant 1.
    float motionAlpha = 1.0;
#if POPCORN_HAS_VC
    if (HAS_VC)
    {
        // The motion vector is premultiplied by the vertex-colour alpha as
        // well as tinted by vc.xy (matches the retail `motion *= vc.xy`
        // followed by `motion *= vc.w`); vc.w also drives the output alpha.
        motion      *= input.vertColor.xy * input.vertColor.w;
        motionAlpha  = input.vertColor.w;
    }
#endif

    if (HAS_SP) motion *= softFade;

    // Re-bias to [0, 1] for the RT format. .z is forced to zero
    // (the engine reserves it as a "no special encoding" flag).
    float4 outColor;
    outColor.xy = motion * 0.5 + 0.5;
    outColor.z  = 0.0;
    outColor.w  = motionAlpha;
    return outColor;
}
