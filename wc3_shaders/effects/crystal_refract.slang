// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Crystal refraction helpers — Warcraft III Reforged 3.0.0.
//
// `crystal_ps` is not a cousin of the HD mesh shader; it IS the HD mesh shader
// with the AO_MAP axis removed and three pieces of material math swapped in.
// Two of those three live here — the third is simply that crystal decodes the
// normal map raw where HD scales it by the per-draw strength.
//
//   1. An "albedo refraction". The albedo map is sampled at `uv` AND at a
//      second UV offset along the projected VERTEX normal, and the two rgb
//      values are lerped by (1 - refractMask). A fully refracted pixel
//      (refractMask = 0) takes the offset sample entirely — giving the
//      characteristic smear of whatever is painted behind the facet — while an
//      opaque pixel (refractMask = 1) keeps the centre sample. Only rgb is
//      blended; the alpha is always the centre sample's, since it drives the
//      cloak / fresnel alpha downstream and the refraction must not perturb the
//      shape of the transparency.
//
//   2. A "refract-modulated Fresnel alpha". The rim alpha PARAMETER — not the
//      weighted result — is remapped so fully-refracted pixels use a flat 0.2
//      floor, ensuring a transparent body still picks up a visible hero rim.
//
// Both take `refractMask` as a parameter rather than resampling it: the shipped
// bytecode fetches `t2.x` once and feeds the same `1 - mask` to the albedo lerp
// and to the Fresnel remap.

implementing wc3_shaders;

// Per-pixel UV-space radius of the refracted albedo fetch. Grazing-angle
// pixels (small |n.z|) get a larger offset, which produces the wider colour
// smear around a facet's silhouette; near-axis pixels see almost none.
public static const float CRYSTAL_REFRACT_SCALE    = 0.0199999996;

// Fresnel-overlay weight substituted when the surface is fully refracted
// (refractMask = 0). Numerically equal to the cloak's base alpha bias but used
// here only as a Fresnel mix endpoint — deliberately given its own name so a
// future tweak to either constant does not drift silently.
public static const float CRYSTAL_FRESNEL_NOREFRACT = 0.200000003;

// Sample the albedo map at the UV and at the refraction-offset UV, lerp between
// them by (1 - refractMask), and preserve the centre sample's alpha.
//
// The offset is driven by the INTERPOLATED vertex normal, not by the
// normal-mapped shading normal — the shipped shader reads TEXCOORD2 directly,
// before the normal map is decoded, so a bumpy surface refracts along its
// geometric facet rather than along its texture detail. `abs()` on the view-z
// keeps the sample direction consistent for front and back faces, so a cloaked
// back face still refracts toward its silhouette.
//
// The `-` on `.z` below is ARITHMETICALLY DEAD and is kept deliberately. `.z`
// is consumed only through `abs()`, which clears the sign bit, so negating it
// cannot reach any observable value — measured at exactly 0.0 worst relative
// difference over 400k random normals, and true by construction rather than by
// luck. It stays because it is what the shipped instruction computes (a `mad`
// against (0, 0, -2) producing the whole view-space vector before the `abs`),
// and because writing `float3(normalWS.xy, normalWS.z)` would read as if the
// projection had been forgotten. Do not expect a differential to defend it:
// P6's harness measured that mutation MISSED and then proved it inert, rather
// than recording a gate hole.
public float4 sampleCrystalAlbedo(float2 uv, float3 normalWS, float refractMask)
{
    float4 centre = t_hdAlbedo.Sample(s_hdAlbedo, uv);

    float3 viewNrm   = float3(normalWS.xy, -normalWS.z);
    float  scale     = CRYSTAL_REFRACT_SCALE / abs(viewNrm.z);
    float2 uvRefract = viewNrm.xy * scale + uv;

    float3 offset = t_hdAlbedo.Sample(s_hdAlbedo, uvRefract).xyz;
    float3 rgb    = lerp(centre.xyz, offset, 1.0 - refractMask);
    return float4(rgb, centre.w);
}

// Remap the Fresnel-overlay alpha parameter by the refract mask. At
// refractMask = 1 the result is the authored `fresnelColor.w`; at
// refractMask = 0 it clamps to CRYSTAL_FRESNEL_NOREFRACT so the rim stays
// visible through a fully transparent pixel.
//
// This feeds `hdFresnelAndCloakA`'s parameter, which means it reaches the rim
// COLOUR mix and `plainAlpha` alike — both are built from the same weighted
// value, and the shipped shader shares that register.
public float refractModulatedFresnelAlpha(float fresnelAlpha, float refractMask)
{
    return (1.0 - refractMask) * (CRYSTAL_FRESNEL_NOREFRACT - fresnelAlpha) + fresnelAlpha;
}

// The crystal shading normal: the normal map decoded RAW.
//
// HD runs an encode/decode round trip that scales the tangent-space XY by
// `hdPsCB2.normalStrength` (cb2[27].x). Crystal never reads that lane — checked
// across all 512 shipped permutations — so the whole round trip, including its
// deliberately asymmetric saturate, is absent here rather than being run with a
// strength of one.
public float3 crystalWorldNormal(HDPSInput input, bool isFrontFace)
{
    float3 tsN = decodeNormalMap(t_hdNormal.Sample(s_hdNormal, input.uv.xy).xyw);
    float3 n = tangentToWorld(tsN, input.tangentWS.xyz, input.normalWS,
                              input.tangentWS.w);
    return orientNormal(n, isFrontFace);
}
