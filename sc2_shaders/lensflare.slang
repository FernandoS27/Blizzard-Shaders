// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// LensFlare family (lensflare.fx) — VS + PS.
//
// Screen-space flare sprites read from an atlas, optionally modulated by a
// dirty-lens texture sampled in screen space, then faded by fog of war.
// `LensFlare_BuildSection` @0x102b53f90 registers one own axis and links
// [Common, FOW] (in that order — RenderPlane links the same pair reversed):
//
//     b_shaderMode @104 w1   0 = atlas only, 1 = atlas * dirty lens
//
// The vertex shader takes the clip-space position straight from the stream
// (`vPositionUV.xy`) — there is no transform — and passes the same value on as
// `vUVScreenPos.zw` for the dirty-lens lookup.  It declares its own
// `VertexTransport`, hence `inject_preamble: false`.

implementing sc2_shaders;

#ifndef b_shaderMode
#define b_shaderMode 0
#endif

public struct LensFlareVSInput
{
    float4 vColor      : COLOR0;
    float  hdrScale    : COLOR1;
    float2 vFOWUV      : TEXCOORD1;
    float4 vPositionUV : POSITION;
};

// lensflare.fx : VertexTransport.  `vPosition` exists only under VERTEX_SHADER,
// so the pixel side sees the other three fields.
public struct LensFlareTransport
{
    float4 vUVScreenPos : TEXCOORD0;
    float4 vColor       : COLOR0;
    float2 vFOWUV       : TEXCOORD1;
    float4 vPosition    : SV_Position;
};

public struct LensFlarePSInput
{
    float4 vUVScreenPos : TEXCOORD0;
    float4 vColor       : COLOR0;
    float2 vFOWUV       : TEXCOORD1;
};

[shader("vertex")]
public LensFlareTransport lensflare_vs_main(LensFlareVSInput vertIn)
{
    LensFlareTransport vertOut;

    vertOut.vPosition = float4(vertIn.vPositionUV.xy, .5f, 1.f);
    vertOut.vColor = vertIn.vColor.rgba * vertIn.hdrScale;
    vertOut.vFOWUV = vertIn.vFOWUV;
    vertOut.vUVScreenPos.xy = vertIn.vPositionUV.zw;
    vertOut.vUVScreenPos.zw = vertOut.vPosition.xy / vertOut.vPosition.w;

    return vertOut;
}

[shader("pixel")]
public float4 lensflare_ps_main(LensFlarePSInput vertIn) : SV_Target0
{
    float4 rvalue = float4(0.f, 0.f, 0.f, 0.f);
#if (b_shaderMode == 0)
    rvalue = vertIn.vColor * p_sAtlas_t.Sample(p_sSamp, vertIn.vUVScreenPos.xy);
#elif (b_shaderMode == 1)
    rvalue = vertIn.vColor * p_sAtlas_t.Sample(p_sSamp, vertIn.vUVScreenPos.xy)
           * p_sDirtyLens_t.Sample(p_sSamp, .5f * vertIn.vUVScreenPos.zw + .5f);
#endif

    float3 stubDiffuse = float3(0, 0, 0);
    rvalue.xyz = applyFogOfWar(ndc2Tex(vertIn.vFOWUV.xy), rvalue, stubDiffuse).xyz;
    return rvalue;
}
