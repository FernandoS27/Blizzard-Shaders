// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Cross-backend shims.
//
// Every Diablo III vertex shader writes six user clip planes as
// SV_ClipDistance0/1, and most pixel shaders declare them as (unread) inputs so
// their register layout matches the paired vertex shader. Only the D3D targets
// carry them in the interpolant struct; D3_TARGET_WGSL / D3_TARGET_METAL builds
// drop them (types/transport.slang), which is the only portability difference
// a root ever sees.

implementing d3_shaders;

/// `saturate` whose NaN behaviour survives fxc: marked `precise` on the D3D
/// targets so d3dcompiler_47 keeps retail's `*_sat` clamp instead of spelling a
/// known-non-negative clamp as `min(x, 1)` (which maps NaN to 1, not 0). The
/// keyword is HLSL-only; other backends get a plain saturate.
public float d3SaturateExact(float x)
{
    __target_switch
    {
    case hlsl:
        precise float clamped = saturate(x);
        return clamped;
    default:
#ifdef D3_TARGET_FLAKES
        // the engine runs these: D3D maps NaN to 0, SPIR-V's FClamp leaves it
        // undefined (and a driver may spell it min(., 1) as fxc does)
        return isnan(x) ? 0.0 : saturate(x);
#else
        return saturate(x);
#endif
    }
}

/// `int3(x)` with D3D's ftoi on every backend: NaN reads 0 and a value past the
/// int range its limit. WGSL / SPIR-V leave both undefined (naga clamps to
/// 2^31 - 128 first, so a NaN reads -2^31).
public int3 d3FtoiExact(float3 x)
{
    __target_switch
    {
    case hlsl:
        return int3(x);
    default:
#ifdef D3_TARGET_FLAKES
        float3 finite = select(isnan(x), float3(0.0, 0.0, 0.0), x);
        int3 r = int3(clamp(finite, -2147483648.0, 2147483520.0));
        return select(finite >= 2147483648.0, int3(2147483647, 2147483647, 2147483647), r);
#else
        return int3(x);
#endif
    }
}
