// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// RenderPlane family (renderplane.fx) — VS + PS.
//
// The smallest family in the set: a single quad stretched over the map that
// paints the fog-of-war black mask, with the FOW coverage in alpha.  It has NO
// own permutation axes at all — `RenderPlane_BuildSection` @0x102b66420 registers
// only uniforms and links two shared sub-sections, **FOW first and Common
// second** (LensFlare links the same pair the other way round, so the link order
// really is per-family).  Its four retail permutations are exactly the FOW
// fast/slow × encoding combinations.
//
// It declares its own `VertexTransport`, so the shared interpolant transport is
// NOT injected into the reference compile (`inject_preamble: false`).

implementing sc2_shaders;

public struct RenderPlaneVSInput
{
    float4 vPosition : POSITION;
};

// renderplane.fx : VertexTransport.  The original names the position `vHPos :
// POSITION`; on a vs_5_0 target that is an ordinary output semantic, and the
// comparator maps POSITION -> HPos on both legs.
public struct RenderPlaneTransport
{
    float4 vHPos  : SV_Position;
    float4 vFowUV : TEXCOORD0;
};

[shader("vertex")]
public RenderPlaneTransport renderplane_vs_main(RenderPlaneVSInput streamIn)
{
    RenderPlaneTransport vertOut;
    float4 vPosition = streamIn.vPosition;      // the original mutates its `in` param

    vPosition.xyz *= vsGlobals.vSize;
    vPosition.xyz += vsGlobals.vOffset;
    vertOut.vFowUV = mul(vPosition, vsGlobals.mFOWMatrix);
    vertOut.vHPos = mul(vPosition, vsGlobals.mWorldViewProj);
    return vertOut;
}

public struct RenderPlanePSInput
{
    float4 vHPos  : SV_Position;
    float4 vFowUV : TEXCOORD0;
};

[shader("pixel")]
public float4 renderplane_ps_main(RenderPlanePSInput vertOut) : SV_Target0
{
    // Note: the ndc->tex conversion is written out here rather than routed through
    // ndc2Tex(), because renderplane.fx open-codes it with a trailing scalar `+ 0.5f`
    // (identical arithmetic, kept literal).
    float2 fowUv = vertOut.vFowUV.xy * float2(0.5f, -0.5f) + 0.5f;
    float4 cResult = float4(1, 1, 1, 1);
    float3 cStub = float3(0, 0, 0);
    cResult = applyFogOfWar(fowUv, cResult, cStub);
    return float4(psGlobals.cFOWBlackMaskColor, 1.0f - cResult.r);
}
