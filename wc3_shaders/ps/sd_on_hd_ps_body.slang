// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// The SD-on-HD material, cloak and depth prepass — Reforged 3.0.0.
//
// 3.0.0 moved SD assets onto the HD pipeline wholesale. This family now shares
// the HD vertex shader, the HD constant buffers, the HD textures, the HD
// clustered-forward light loop, the HD cascade and cube shadows and the HD fog
// block. What is left in this file is only what the two genuinely do
// differently, and every one of those differences follows from a single fact:
// an SD asset is a diffuse texture and nothing else.
//
//   * The material is albedo alone. t1 (normal), t2 (ORM), t3 (emissive) and
//     t4 (team colour) are never sampled, so the shading normal is the
//     interpolated geometric one and there is no emissive, ambient occlusion
//     or team layer. TEXCOORD3 still arrives from the shared vertex shader
//     and is ignored.
//   * `metal = 0` and `rough = 1` are consequently compile-time constants.
//     They are not defaults standing in for a missing map — they are what the
//     shipped bytecode folds to, and the fold is legible in it: the GGX term
//     collapses to a literal 1/PI, both Schlick k terms to 0.5, the probe mip
//     to the raw mip end, and the split-sum LUT's Fresnel scale drops out
//     because F0 is zero (only the bias lane is sampled).
//   * There is no fresnel rim. In HD the rim and the cloak are one block; here
//     only the cloak survives, so `fresnelColor` (cb2[24]) is never read.
//   * No colour grade before the fog, and an optional sRGB encode after it.

implementing wc3_shaders;

// The shaded point for an SD asset: an albedo-only dielectric.
//
// Every derived term below is the HD expression evaluated at metal 0 and
// roughness 1 — spelled out rather than computed so the reader can check them
// against the shipped constants directly:
//
//   diffColor = (albedo - 0 * albedo) / PI          -> albedo * INV_PI
//   F0        = 0 * albedo                          -> 0
//   a2        = (rough * rough)^2                   -> 1
//   kDirect   = (1 + rough)^2 * 0.125               -> 0.5
//   kInv      = 1 - kDirect                         -> 0.5
//
// `a2 = 1` is what turns HD's GGX into the bare 1/PI the SD blobs contain: the
// denominator becomes `ndh^2 + (1 - ndh^2)`, which is 1 for every normal.
public HDSurface sdOnHdSurface(float3 albedo, float3 N, float3 V)
{
    HDSurface s;
    s.N         = N;
    s.V         = V;
    s.albedo    = albedo;
    s.metal     = 0;
    s.F0        = float3(0, 0, 0);
    s.diffColor = albedo * INV_PI;
    s.rough     = 1;
    s.a2        = 1;
    s.kDirect   = SCHLICK_K_FACTOR * 4;   // (1 + rough)^2 * 0.125 at rough == 1
    s.kInv      = 1 - SCHLICK_K_FACTOR * 4;
    return s;
}

// The alpha a cloaked surface gets, and the one it gets otherwise.
//
// Split out from the colour because the depth prepass needs the alpha on its
// own: a cut-out material's alpha test has to punch exactly the holes the
// colour pass will, and under a cloak that alpha comes from an edge-detect
// ramp rather than from the texture. Two implementations would drift.
public float sdOnHdCloakAlpha(float ndv, float albedoA, float vertAlpha)
{
    float rim = 1.0 - ndv;

    // Peaks where the surface faces the camera edge-on, which is what makes a
    // cloaked unit read as a silhouette rather than as a ghost.
    float edge = min(1.0, HD_EDGE_DETECT_SCALE * (-rim * rim + 1.0));
    float cloakAlpha = edge * HD_CLOAK_EDGE_SCALE + HD_CLOAK_ALPHA_BIAS;
    cloakAlpha = hdPsCB2.cloakAmount * (cloakAlpha - vertAlpha) + vertAlpha;
    cloakAlpha = albedoA * cloakAlpha;

    float plainAlpha = saturate(vertAlpha * albedoA);
    return (0 < hdPsCB2.cloakAmount) ? cloakAlpha : plainAlpha;
}

// Colour and alpha after the cloak.
//
// The cloak is an alternative surface, not a modifier: with it on, the colour
// is the lit result pushed toward a flat grey by the rim and the alpha comes
// from the ramp above. The shipped shader evaluates both and selects, which is
// what this mirrors.
public float4 sdOnHdCloak(float3 shadedRGB, float ndv, float albedoA, float vertAlpha)
{
    float rim2 = (1.0 - ndv) * (1.0 - ndv);
    float3 cloakRGB = hdPsCB2.cloakAmount * ((HD_CLOAK_TINT - shadedRGB) * rim2)
                    + shadedRGB;
    float alpha = sdOnHdCloakAlpha(ndv, albedoA, vertAlpha);
    return float4((0 < hdPsCB2.cloakAmount) ? cloakRGB : shadedRGB, alpha);
}

// ---------------------------------------------------------------------------
// Depth prepass
// ---------------------------------------------------------------------------

// Cheap prepass: the manual depth test and the water clip.
//
// Note the order against HD's: SD runs the depth test BEFORE it touches a
// texture, HD samples its material set first. Both orders are the shipped
// ones; neither is a simplification.
public void sdOnHdPrepassStub(HDPSInput input)
{
    hdDepthTestDiscard(input.svPosition.xy, input.viewPos.z);
    if (input.viewPos.w < 0)
        discard;
}

// Alpha-tested prepass.
//
// Expensive for a depth-only pass, and unavoidably so: for a cloaked unit the
// alpha depends on the edge-detect ramp, which needs the world-space normal.
// A cheaper prepass testing only the texture alpha would disagree with the
// colour pass at every silhouette.
public void sdOnHdPrepassAlpha<TAlpha : IAlphaTest>(HDPSInput input, bool isFrontFace)
{
    hdDepthTestDiscard(input.svPosition.xy, input.viewPos.z);

    float albedoA = t_hdAlbedo.Sample(s_hdAlbedo, input.uv.xy).w;
    float3 N = orientNormal(normalize(input.normalWS), isFrontFace);
    float3 V = normalize(-input.viewPos.xyz);
    float ndv = saturate(dot(V, N));

    float alpha = sdOnHdCloakAlpha(ndv, albedoA, input.vertColor.w);

    if (input.viewPos.w < 0)
        discard;
    TAlpha.test(alpha, hdPsCB2.alphaRef);
}
