// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Depth-only pass for the 3.0.0 crystal pixel shader.
//
// There is only one body here because the PLAIN prepass is not crystal's at
// all: with no alpha test the pass never touches the material, so the engine
// ships HD's program verbatim — `crystal/perm_004` is byte-identical to
// `hd/perm_0008`, declarations included — and `crystal_ps_main` calls
// `hdDepthPrepassStub` directly.
//
// The alpha-tested prepass does differ, because the alpha a cut-out crystal is
// tested against runs through the Fresnel rim, and crystal's rim alpha is
// remapped by the refract mask. So this body is `hdDepthPrepassAlpha` with
// crystal's two material changes and nothing else: the normal map decoded raw
// instead of scaled by the per-draw strength, and the remapped rim alpha. The
// albedo is NOT refracted here — the refraction blends rgb only and leaves the
// centre sample's alpha alone, so the one channel this pass reads is unaffected.

implementing wc3_shaders;

public void crystalDepthPrepassAlpha<TAlpha : IAlphaTest, TMat : IMaterialLayer>(
    HDPSInput input, bool isFrontFace)
{
    float albedoA     = t_hdAlbedo.Sample(s_hdAlbedo, input.uv.xy).w;
    float refractMask = t_hdOrm.Sample(s_hdOrm, input.uv.xy).x;

    hdDepthTestDiscard(input.svPosition.xy, input.viewPos.z);

    float3 N = crystalWorldNormal(input, isFrontFace);
    float3 V = normalize(-input.viewPos.xyz);
    float ndv = saturate(dot(V, N));

    float rim = 1.0 - ndv;
    float fresnelA = refractModulatedFresnelAlpha(hdPsCB2.fresnelColor.w, refractMask)
                   * (rim * rim);
    float plainAlpha = saturate(input.vertColor.w * albedoA + fresnelA * albedoA);

    float edge = min(1.0, HD_EDGE_DETECT_SCALE * (-rim * rim + 1.0));
    float ramp = TMat.hasMultiLayer
               ? (t_hdOrm.Sample(s_hdOrm, input.uv.xy).w * HD_ML_ALPHA_RAMP_SCALE
                  + HD_ML_ALPHA_RAMP_BIAS)
               : HD_CLOAK_EDGE_SCALE;
    float cloakAlpha = edge * ramp + HD_CLOAK_ALPHA_BIAS;
    cloakAlpha = hdPsCB2.cloakAmount * (cloakAlpha - input.vertColor.w) + input.vertColor.w;
    cloakAlpha = albedoA * cloakAlpha;

    float alpha = (0 < hdPsCB2.cloakAmount) ? cloakAlpha : plainAlpha;

    if (input.viewPos.w < 0)
        discard;
    TAlpha.test(alpha, hdPsCB2.alphaRef);
}
