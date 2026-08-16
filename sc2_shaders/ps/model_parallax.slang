// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Model-family parallax / parallax-occlusion mapping (psparallax.fx : ApplyParallax
// and helpers).  ApplyParallax ray-marches the height map and offsets EVERY live UV
// emitter by the resulting parallax vector, so it runs on a mutable copy of the
// interpolants (mainShading's by-value `vertOut`) before any material sample.
//
// The Linear/Binary search (POM-new) and the ComputeParallaxOffset ray-trace (POM-old)
// are branch-driven height-map marches: they carry the documented POM interpreter floor
// (the ε the exit gate excludes), not a logic error.

implementing sc2_shaders;

#ifndef b_useParallaxMapping
#define b_useParallaxMapping 0
#endif
#ifndef b_iUsePOMNew
#define b_iUsePOMNew 0
#endif
#ifndef b_iHeightmapChannelSelect
#define b_iHeightmapChannelSelect 0
#endif
#ifndef b_iNormalUVEmitter
#define b_iNormalUVEmitter 0
#endif
#ifndef b_iUVEmitterCount
#define b_iUVEmitterCount 0
#endif
#ifndef b_usePackedUVEmitter
#define b_usePackedUVEmitter 0
#endif

// psparallax.fx : LinearSearch — 12 fixed steps down the view ray until below the
// height field.
void linearSearch(int iChannels, int iNumSteps, inout float3 vVector, inout float3 vPoint)
{
    vVector /= iNumSteps;
    for (int i = 0; i <= iNumSteps; i++)
    {
        float h = chooseChannel(iChannels, p_sHeightmapSampler_t.Sample(p_sSamp, vPoint.xy)).a;
        if (vPoint.z > h)
            vPoint += vVector;
    }
}

// psparallax.fx : BinarySearch — 4 refinement steps around the intersection.
void binarySearch(int iChannels, int iNumSteps, inout float3 vVector, inout float3 vPoint)
{
    for (int i = 0; i < iNumSteps; i++)
    {
        vVector *= 0.5f;
        float h = chooseChannel(iChannels, p_sHeightmapSampler_t.Sample(p_sSamp, vPoint.xy)).a;
        if (vPoint.z > h)
            vPoint += 2.0f * vVector;
        vPoint -= vVector;
    }
}

// psparallax.fx : ComputeParallaxOffsetNew — the mTangent2World / isDXN args are unused
// in the .fx, so they are dropped.  Always "succeeds" (returns the offset directly).
float2 computeParallaxOffsetNew(float3 vViewVectorTS, float2 vHeightMapUV)
{
    vViewVectorTS /= -vViewVectorTS.z;
    vViewVectorTS.xy *= psGlobals.vSpecularMultiplier_DepthBlendThreshold_HeightMapScale_AlphaFactor.z;

    float3 vUV = float3(vHeightMapUV.xy, 1.0f);
    linearSearch(b_iHeightmapChannelSelect, 12, vViewVectorTS, vUV);
    binarySearch(b_iHeightmapChannelSelect, 4, vViewVectorTS, vUV);
    return vUV.xy - vHeightMapUV;
}

// psparallax.fx : ComputeParallaxOffset (old) — a 16-step ray-trace with the
// intersection interpolation.
float2 computeParallaxOffset(float2 vParallaxVector, float2 vHeightMapUV)
{
    int nNumSteps = 16;
    float2 dx = ddx(vHeightMapUV);
    float2 dy = ddy(vHeightMapUV);

    float  fSampledHeight = 0.0f;
    float  fStepSize = 1.0f / (float)nNumSteps;
    float  fPrevSampledHeight = 1.0f;
    int    nStepIndex = 0;
    float2 vTexOffsetPerStep = fStepSize * vParallaxVector;
    float2 vCurrentSampleUV = vHeightMapUV;
    float  fRayHeight = 1.0f;
    float  fParallaxAmount = 0.0f;
    float  x = 0.0f, y = 0.0f, xh = 0.0f, yh = 0.0f;

    while (nStepIndex < nNumSteps)
    {
        vCurrentSampleUV -= vTexOffsetPerStep;
        fSampledHeight = chooseChannel(b_iHeightmapChannelSelect,
            p_sHeightmapSampler_t.SampleGrad(p_sSamp, vCurrentSampleUV, dx, dy)).a;
        fRayHeight -= fStepSize;
        if (fSampledHeight > fRayHeight)
        {
            x = fRayHeight;
            y = fRayHeight + fStepSize;
            xh = fSampledHeight;
            yh = fPrevSampledHeight;
            nStepIndex = nNumSteps + 1;
        }
        else
        {
            nStepIndex++;
            fPrevSampledHeight = fSampledHeight;
        }
    }
    fParallaxAmount = (x * (y - yh) - y * (x - xh)) / ((y - yh) - (x - xh));
    return vParallaxVector * (1.0f - fParallaxAmount);
}

// psparallax.fx : OffsetUVEmitter — add the parallax offset to one live UV emitter.
// Called with literal indices (unrolled) so the UV-array access stays static.
void offsetUVEmitter(inout ModelPSInput vertOut, int index, float4 offset)
{
#if b_usePackedUVEmitter
    float4 u = vertOut.UV(index / 2);
    if (index % 2 == 0)
        u.xy += offset.xy;
    else
        u.zw += offset.xy;
    vertOut.SetUV(index / 2, u);
#else
    vertOut.SetUV(index, vertOut.UV(index) + offset);
#endif
}

// psparallax.fx : ApplyParallax — offset every UV emitter by the parallax vector
// (POM-new adds +offset, the old ray-trace subtracts it).  The UV-emitter loop is
// unrolled by the compile-time emitter count.
void applyParallax(inout ModelPSInput vertOut, float4 iUV)
{
#if b_useParallaxMapping
    if (psGlobals.vSpecularMultiplier_DepthBlendThreshold_HeightMapScale_AlphaFactor.z <= 0.0f)
        return;

    float4 parallax = float4(0, 0, 0, 0);
    float4 off;
  #if b_iUsePOMNew
    parallax.xy = computeParallaxOffsetNew(vertOut.ParallaxVector(), iUV.xy);
    off = parallax;
  #else
    parallax.xy = computeParallaxOffset(vertOut.ParallaxVector().xy, iUV.xy);
    off = -parallax;
  #endif

  #if (b_iUVEmitterCount > 0)
    offsetUVEmitter(vertOut, 0, off);
  #endif
  #if (b_iUVEmitterCount > 1)
    offsetUVEmitter(vertOut, 1, off);
  #endif
  #if (b_iUVEmitterCount > 2)
    offsetUVEmitter(vertOut, 2, off);
  #endif
  #if (b_iUVEmitterCount > 3)
    offsetUVEmitter(vertOut, 3, off);
  #endif
  #if (b_iUVEmitterCount > 4)
    offsetUVEmitter(vertOut, 4, off);
  #endif
  #if (b_iUVEmitterCount > 5)
    offsetUVEmitter(vertOut, 5, off);
  #endif
  #if (b_iUVEmitterCount > 6)
    offsetUVEmitter(vertOut, 6, off);
  #endif
  #if (b_iUVEmitterCount > 7)
    offsetUVEmitter(vertOut, 7, off);
  #endif
#endif
}
