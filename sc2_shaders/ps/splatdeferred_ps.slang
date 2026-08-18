// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// SplatDeferred pixel shader entry (splatdeferred.fx : SplatDeferredPixelMain).
//
// The deferred splat PS optionally reconstructs world position from the scene depth
// buffer (b_iSplatBoxRender) — clipping the fragment against the splat's unit cube
// and updating the world/view interpolants — then tail-calls DefaultPixelMain.  The
// permutation key is the Model family schema (SplatDeferred links the identical
// shared sub-sections + MainShading; its header ceils to the same byte as Model) plus
// three own axes at physical bits 104/105/106: b_iUseHardwareDepth / b_iUseMinimumHeight
// / b_iSplatBoxRender (SplatDeferred_BuildFamily @0x102b91d20).  Every retail perm is
// VECTORUI shading mode, so the box-render's SHADINGMODE_STANDARD interpolant/lighting
// reconstruction (splatdeferred.fx:220-287) is unreachable (measured) and not transcribed.

implementing sc2_shaders;

#ifndef b_iSplatBoxRender
#define b_iSplatBoxRender 0
#endif
#ifndef b_iUseHardwareDepth
#define b_iUseHardwareDepth 0
#endif

// splatdeferred.fx : SampleDepth — raw hardware depth vs encoded view depth.
float splatSampleDepth(float2 depthUV)
{
    float4 sampledDepth = p_sDepthMap_t.Sample(p_sSamp, depthUV);
#if b_iUseHardwareDepth
    return sampledDepth.x;
#else
    return decodeDepth(sampledDepth);
#endif
}

// splatdeferred.fx : ReconstructViewPos — projection-inverse (hardware depth) or the
// cheaper XZ-scale reconstruction (view depth).
float4 splatReconstructViewPos(float depth, float2 depthUV)
{
    float2 projectedXYPos = float2(depthUV.x * 2.0f - 1.0f, (1.0f - depthUV.y) * 2.0f - 1.0f);
    float4 viewPos;
#if b_iUseHardwareDepth
    float4 projectedPos = float4(projectedXYPos, depth, 1.0f);
    viewPos = mul(projectedPos, psGlobals.mProjectionInv);
    viewPos = viewPos / viewPos.w;
#else
    viewPos.xz = depth * projectedXYPos;
    viewPos.xz *= psGlobals.vProjectionXZInv;
    viewPos.yw = float2(depth, 1.0f);
#endif
    return viewPos;
}

[shader("fragment")]
public ModelPSOutput splatdeferred_ps_main(ModelPSInput vertOut)
{
#if b_iSplatBoxRender
    {
        // Reconstruct world position from the depth buffer and clip to the unit cube
        // (splatdeferred.fx:195-217).  The PS_30-only +0.5 screen offset is DCE'd for
        // the ps_5_0 target.  INTERPOLANT_ScreenPos == SV_Position (gen_preamble).
        float2 screenPos = vertOut.HPos.xy;
        float2 depthUV = screenPos * psGlobals.vResolutionRcp;
        float2 viewUV = screenPos * psGlobals.vViewOffsetMul.zw + psGlobals.vViewOffsetMul.xy;
        float depth = splatSampleDepth(depthUV);
        float4 viewPos = splatReconstructViewPos(depth, viewUV);
        float4 worldPos = mul(viewPos, psGlobals.mViewInvTransform44);
        float4 objPos = mul(worldPos, psGlobals.mWorldInvTransform);
        sc2_clip(0.5f - abs(objPos.xyz) + 0.001f);     // c_fEpsilon = 0.001
    #if SC2_HAS_ViewPos
        vertOut.m_ViewPos = viewPos.xyz;           // WRITE_INTERPOLANT_ViewPos
    #endif
    #if SC2_HAS_WorldPos
        vertOut.m_WorldPos = worldPos;             // WRITE_INTERPOLANT_WorldPos
    #endif
    }
#endif
    return computeModelPixel(vertOut);
}
