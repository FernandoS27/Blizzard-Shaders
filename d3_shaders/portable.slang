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
        return saturate(x);
    }
}
