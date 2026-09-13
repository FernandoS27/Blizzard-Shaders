// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Depth-only passes for the 3.0.0 HD mesh pixel shader.
//
// The prepass writes no colour — the rasteriser takes depth from SV_Position —
// so both bodies exist purely to decide which fragments live. The permutation
// ignores every shading axis: the engine emits identical bytecode for the bare
// prepass slot and for the prepass slot with lighting and shadows set, which
// is why lighting resources must not even be declared here.

implementing wc3_shaders;

// Cheap prepass: the manual depth test and the water clip plane.
public void hdDepthPrepassStub(HDPSInput input)
{
    hdDepthTestDiscard(input.svPosition.xy, input.viewPos.z);
    if (input.viewPos.w < 0)
        discard;
}

// Alpha-tested prepass.
//
// Expensive for a depth pass, and unavoidably so: the alpha a cut-out material
// is tested against depends on the fresnel rim and — for a cloaked unit — on
// an edge-detect ramp, both of which need the world-space normal. A cheaper
// prepass that tested only the texture alpha would punch different holes than
// the colour pass and the two would disagree at every silhouette.
public void hdDepthPrepassAlpha<TAlpha : IAlphaTest, TMat : IMaterialLayer>(
    HDPSInput input, bool isFrontFace)
{
    float albedoA = t_hdAlbedo.Sample(s_hdAlbedo, input.uv.xy).w;
    float2 enc = encodeScaledNormal(
        t_hdNormal.Sample(s_hdNormal, input.uv.xy).xyw, hdPsCB2.normalStrength);

    hdDepthTestDiscard(input.svPosition.xy, input.viewPos.z);

    float3 N = hdWorldNormal(input, enc, isFrontFace);
    float3 V = normalize(-input.viewPos.xyz);
    float ndv = saturate(dot(V, N));

    float rim = 1.0 - ndv;
    float fresnelA = hdPsCB2.fresnelColor.w * (rim * rim);
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
