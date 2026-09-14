// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// 3.0.0 distance-fog survival factors — one implementation, two selections.
//
// 2.0.0 gave every family its own fog: the HD shaders had FOG_LINEAR /
// FOG_EXPONENTIAL as permutation axes, the classic SD shader had its own
// three-mode chain, and each wrote the maths out again. 3.0.0 unified them on
// a single seven-mode enum. What did *not* unify is how the mode is chosen:
//
//   • `hd_ps` / `sd_on_hd_ps` read the mode from their per-draw bank and
//     select at runtime (see `hdDistanceFog`), which is why a 3.0.0 HD blob
//     contains every arm at once.
//   • `sd_classic_ps` bakes the mode into the permutation and selects at
//     compile time through `IFogMode30`, which is why its blobs contain
//     exactly one arm — and why its first seven permutations are the seven
//     modes in isolation.
//
// Both call the arms below, so there is one implementation of each mode.
//
// A *survival factor* is 1 where the surface colour is untouched and 0 where
// it is entirely replaced. How a family APPLIES that factor is its own
// business — `sd_classic_ps` lerps plainly toward the fog colour while the HD
// families run an 11-case blend-mode switch so additive fades to black and
// modulate to white — so this file deliberately stops at the factor.
//
// Mode 4 is volumetric fog and is NOT here: it needs a world position and a
// fog volume, so it lives in `hdVolumetricFog`. Families without a volumetric
// implementation alias mode 4 onto mode 0; that is measured, not assumed —
// `sd_classic_ps` emits mode 0's bytecode for mode 4 in all 50 of its
// (alpha, stage0, stage1) combinations, and `fog_ps` ships 7 perms with only
// 6 distinct blobs for the same reason.

implementing wc3_shaders;

// Shared by every ranged mode (1, 5, 6). The clamp is what stops a fogEnd at
// or below fogStart from producing an infinite range; SAFE_EPS is the same
// 0.001 the shipped bytecode adds before the max.
public float fogInvRange(float fogStart, float fogEnd)
{
    float clampedEnd = max(fogEnd, SAFE_EPS + fogStart);
    return 1.0 / (clampedEnd - fogStart);
}

// Distance normalised into [0,1] across the fog band — the input to modes 5
// and 6. Note the asymmetry with mode 1, which is NOT normalised the same way:
// it scales `fogEnd - viewZ` by the clamped inverse range but keeps the raw
// `fogEnd` in the numerator.
public float fogBandT(float viewZ, float fogStart, float fogEnd)
{
    return saturate(fogInvRange(fogStart, fogEnd) * (viewZ - fogStart));
}

// Common tail. The Hermite remap reaches 1 with zero derivative, so the fog
// wall fades out smoothly instead of banding at its own start; the saturate
// is what makes `min(1, ...)` unnecessary in the exponential arms.
public float fogSmoothTail(float f)
{
    f = saturate(f);
    return -f * f + (f + f);
}

// mode 1 — linear ramp between fogStart and fogEnd.
public float fogFactorLinear(float viewZ, float fogStart, float fogEnd)
{
    return fogInvRange(fogStart, fogEnd) * (fogEnd - viewZ);
}

// mode 2 — exp(-density * z). The only mode that ignores the fog range.
public float fogFactorExp(float viewZ, float fogDensity)
{
    return 1.0 / exp(fogDensity * viewZ);
}

// mode 3 — exp(-(density * z)²): slower onset, sharper drop-off.
public float fogFactorExpSq(float viewZ, float fogDensity)
{
    return 1.0 / exp((fogDensity * fogDensity) * (viewZ * viewZ));
}

// mode 5 — mode 2 driven by the normalised band distance rather than raw z,
// so the curve is bounded by fogEnd instead of running away with depth.
public float fogFactorExpBand(float viewZ, float fogStart, float fogEnd, float fogDensity)
{
    return 1.0 / exp(fogDensity * fogBandT(viewZ, fogStart, fogEnd));
}

// mode 6 — mode 3 driven by the normalised band distance.
public float fogFactorExpSqBand(float viewZ, float fogStart, float fogEnd, float fogDensity)
{
    float t = fogBandT(viewZ, fogStart, fogEnd);
    return 1.0 / exp((fogDensity * fogDensity) * (t * t));
}

// ---------------------------------------------------------------------------
// Compile-time selection, for families that spend the mode as a permutation
// axis. The struct names carry the engine's own mode number because that
// number is the ground truth the mapper indexes by — and the gap where
// `FogMode4` would be is the documentation of the volumetric fold.
// ---------------------------------------------------------------------------

public interface IFogMode30
{
    // Lets callers skip fog-dependent setup entirely; `FogMode0None` is the
    // only member for which this is false.
    static const bool hasFog;

    // Final survival factor, smoothstep tail included.
    static float factor(float viewZ, float fogStart, float fogEnd, float fogDensity);
};

// mode 0 (and mode 4 wherever volumetric fog is unimplemented).
public struct FogMode0None : IFogMode30
{
    static const bool hasFog = false;
    static float factor(float viewZ, float fogStart, float fogEnd, float fogDensity)
    {
        return 1.0;
    }
};

public struct FogMode1Linear : IFogMode30
{
    static const bool hasFog = true;
    static float factor(float viewZ, float fogStart, float fogEnd, float fogDensity)
    {
        return fogSmoothTail(fogFactorLinear(viewZ, fogStart, fogEnd));
    }
};

public struct FogMode2Exp : IFogMode30
{
    static const bool hasFog = true;
    static float factor(float viewZ, float fogStart, float fogEnd, float fogDensity)
    {
        return fogSmoothTail(fogFactorExp(viewZ, fogDensity));
    }
};

public struct FogMode3ExpSq : IFogMode30
{
    static const bool hasFog = true;
    static float factor(float viewZ, float fogStart, float fogEnd, float fogDensity)
    {
        return fogSmoothTail(fogFactorExpSq(viewZ, fogDensity));
    }
};

public struct FogMode5ExpBand : IFogMode30
{
    static const bool hasFog = true;
    static float factor(float viewZ, float fogStart, float fogEnd, float fogDensity)
    {
        return fogSmoothTail(fogFactorExpBand(viewZ, fogStart, fogEnd, fogDensity));
    }
};

public struct FogMode6ExpSqBand : IFogMode30
{
    static const bool hasFog = true;
    static float factor(float viewZ, float fogStart, float fogEnd, float fogDensity)
    {
        return fogSmoothTail(fogFactorExpSqBand(viewZ, fogStart, fogEnd, fogDensity));
    }
};
