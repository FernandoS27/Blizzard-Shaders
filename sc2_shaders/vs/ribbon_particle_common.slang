// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Shared Ribbon/Particle vertex helpers (ribbonparticlecommon.fx, plus the two
// pieces of common.fx / vselementutils.fx those two roots pull in).
//
// Both GPU-simulated families age a particle/ribbon vertex over its lifetime and
// interpolate size, colour and rotation from three keyframes; `InterpolateValue`
// is that interpolator and `CalculateDisplacmentAndVelocity` is the closed-form
// drag+gravity integrator that gives them procedural positions without CPU work.

implementing sc2_shaders;

#include "vs/model_vs_defines.slangh"

// ---------------------------------------------------------------------------
// common.fx — the scalar helpers the interpolator is built from.
// ---------------------------------------------------------------------------
float vsSmoothStep(float fX)
{
    return fX * fX * (3.0f - 2.0f * fX);
}

// Quadratic bezier.
float vsBezierInterpolation(float fV0, float fV1, float fV2, float fT)
{
    float invT = (1.0f - fT);
    float ret = (invT * invT) * fV0;
    ret += (2.0f * fT * invT) * fV1;
    ret += (fT * fT) * fV2;
    return ret;
}

float3 vsBezierInterpolation(float3 fV0, float3 fV1, float3 fV2, float fT)
{
    float invT = (1.0f - fT);
    float3 ret = (invT * invT) * fV0;
    ret += (2.0f * fT * invT) * fV1;
    ret += (fT * fT) * fV2;
    return ret;
}

// ---------------------------------------------------------------------------
// ribbonparticlecommon.fx : InterpolateValue.
//
// `interpolation` is a compile-time axis at every call site
// (b_iRibbon{Size,Color}Interpolation / b_iParticle{Size,Color,Rotation}-
// Interpolation), so the chain folds to one arm exactly as it does in the
// original.
//
// CAUTION: the scalar and float3 overloads are NOT the same function with a
// widened type — their BEZIER_WITH_HOLD arms genuinely differ.  The scalar one
// rescales `age` and collapses one control point, then runs a SINGLE bezier; the
// float3 one is a three-way branch that builds a fresh middle control point by
// lerping with `midTimeHold`, and holds `value1` flat between t0 and t1.  Both
// are transcribed verbatim below.
// ---------------------------------------------------------------------------
float vsInterpolateValue(float age, float value0, float value1, float value2,
                         float midTime, float inversedMidTime, float midTimeHold,
                         int interpolation)
{
    float ret = value0;

    if (interpolation == INTERPOLATION_BEZIER)
    {
        ret = vsBezierInterpolation(value0, value1, value2, age);
    }
    else if (interpolation == INTERPOLATION_LINEAR)
    {
        if (age < midTime)
        {
            float fT = age * inversedMidTime;
            ret = lerp(value0, value1, fT);
        }
        else
        {
            float fT = (age - midTime) / (1.0f - midTime);
            ret = lerp(value1, value2, fT);
        }
    }
    else if (interpolation == INTERPOLATION_LINEAR_SMOOTH)
    {
        if (age < midTime)
        {
            float fT = age * inversedMidTime;
            fT = vsSmoothStep(fT);
            ret = lerp(value0, value1, fT);
        }
        else
        {
            float fT = (age - midTime) / (1.0f - midTime);
            fT = vsSmoothStep(fT);
            ret = lerp(value1, value2, fT);
        }
    }
    else if (interpolation == INTERPOLATION_LINEAR_WITH_HOLD)
    {
        float t0 = (midTime - midTimeHold);
        float t1 = (midTime + midTimeHold);
        if (age < t0)
            ret = lerp(value0, value1, age / t0);
        else if (age < t1)
            ret = value1;
        else
            ret = lerp(value1, value2, (age - t1) / (1.0f - t1));
    }
    else if (interpolation == INTERPOLATION_BEZIER_WITH_HOLD)
    {
        // Two piecewise quadratic beziers, expressed as one by rewriting the
        // inputs (the scalar form — see the note above).
        float t0 = (midTime - midTimeHold);
        float t1 = (midTime + midTimeHold);
        float a = age;
        float v0 = value0;
        float v2 = value2;
        if (a < t0)
        {
            a = a / t0;
            v2 = value1;
        }
        else
        {
            a = (a - t1) / (1.0f - t1);
            v0 = value1;
        }
        a = saturate(a);
        ret = vsBezierInterpolation(v0, value1, v2, a);
    }

    return ret;
}

float3 vsInterpolateValue(float age, float3 value0, float3 value1, float3 value2,
                          float midTime, float inversedMidTime, float midTimeHold,
                          int interpolation)
{
    float3 ret = value0;

    if (interpolation == INTERPOLATION_BEZIER)
    {
        ret = vsBezierInterpolation(value0, value1, value2, age);
    }
    else if (interpolation == INTERPOLATION_LINEAR)
    {
        if (age < midTime)
        {
            float fT = age * inversedMidTime;
            ret = lerp(value0, value1, fT);
        }
        else
        {
            float fT = (age - midTime) / (1.0f - midTime);
            ret = lerp(value1, value2, fT);
        }
    }
    else if (interpolation == INTERPOLATION_LINEAR_SMOOTH)
    {
        if (age < midTime)
        {
            float fT = age * inversedMidTime;
            fT = vsSmoothStep(fT);
            ret = lerp(value0, value1, fT);
        }
        else
        {
            float fT = (age - midTime) / (1.0f - midTime);
            fT = vsSmoothStep(fT);
            ret = lerp(value1, value2, fT);
        }
    }
    else if (interpolation == INTERPOLATION_LINEAR_WITH_HOLD)
    {
        float t0 = (midTime - midTimeHold);
        float t1 = (midTime + midTimeHold);
        if (age < t0)
            ret = lerp(value0, value1, age / t0);
        else if (age < t1)
            ret = value1;
        else
            ret = lerp(value1, value2, (age - t1) / (1.0f - t1));
    }
    else if (interpolation == INTERPOLATION_BEZIER_WITH_HOLD)
    {
        // The VECTOR form: a real three-way branch with a lerp-built middle
        // control point, and no saturate.  (Differs from the scalar overload.)
        float t0 = (midTime - midTimeHold);
        float t1 = (midTime + midTimeHold);
        if (age < t0)
            ret = vsBezierInterpolation(value0, lerp(value0, value1, midTimeHold),
                                        value1, age / t0);
        else if (age < t1)
            ret = value1;
        else
            ret = vsBezierInterpolation(value1, lerp(value1, value2, midTimeHold),
                                        value2, (age - t1) / (1.0f - t1));
    }

    return ret;
}

// ---------------------------------------------------------------------------
// vselementutils.fx : CalculateDisplacmentAndVelocity  [sic — the original's
// spelling].  Closed-form solution of  m dv/dt = mg - k v  : the displacement
// and instantaneous velocity of a particle launched at `vInitialVelocity` after
// `fElapsedTime` under gravity `fGravity` and linear drag `fDrag`.
// ---------------------------------------------------------------------------
void vsCalculateDisplacmentAndVelocity(float fElapsedTime, float3 vInitialVelocity,
                                       float fMass, float fInvMass,
                                       float fDrag, float fInvDrag, float fGravity,
                                       out float3 vDisplacement, out float3 vVelocity)
{
    float3 vGravity = float3(0, 0, fGravity);
    float3 vMG = fMass * vGravity;
    float3 vMassTimesGravityOverDrag = vMG * fInvDrag;
    float fExpTerm = exp(-fDrag * fInvMass * fElapsedTime);

    // displacement
    {
        float3 vTerm0a = -(vInitialVelocity + vMassTimesGravityOverDrag);
        float fTerm0b = fMass * fInvDrag;
        float3 vTerm0 = vTerm0a * fTerm0b * fExpTerm;
        float3 vTerm1 = fElapsedTime * vMassTimesGravityOverDrag;
        float3 vTerm2 = fTerm0b * (vInitialVelocity + vMassTimesGravityOverDrag);
        vDisplacement = vTerm0 - vTerm1 + vTerm2;
    }

    // instantaneous velocity
    {
        float3 vTerm0 = fInvDrag * fExpTerm * (fDrag * vInitialVelocity + vMG);
        vVelocity = vTerm0 - vMassTimesGravityOverDrag;
    }
}

// ---------------------------------------------------------------------------
// ribbonparticlecommon.fx : p_mPRWorldTransform[] — the per-batch emitter
// transform both roots use for their local-space paths.  Matrix ARRAYS are stored
// as their float4 rows (VS_MATROWS) because slangc does not apply its row-major
// storage wrapper to array members — see types/model_vs_io.slang.
// ---------------------------------------------------------------------------
float4x4 vsPRWorldMatrix(int i)
{
    int b = i * 4;
    return float4x4(vsGlobals.mPRWorldTransform[b + 0],
                    vsGlobals.mPRWorldTransform[b + 1],
                    vsGlobals.mPRWorldTransform[b + 2],
                    vsGlobals.mPRWorldTransform[b + 3]);
}

// ---------------------------------------------------------------------------
// ribbon.fx / particle.fx : SafeNormalize — normalize with an explicit fallback
// for degenerate vectors (both roots define it identically).
// ---------------------------------------------------------------------------
float3 vsSafeNormalize(float3 v, float3 d)
{
    if (length(v) < 0.00001f)
        return d;

    return normalize(v);
}
