// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Cross-backend shims for HLSL intrinsics Slang only declares for the D3D
// targets.
//
// The `.fx` sources this module reconstructs are HLSL, so the natural
// transcription of an alpha test is `clip(x)`.  Slang declares `clip` with
// `require(hlsl)`, so any entry point that reaches one fails to compile for
// `metal` / `wgsl` (error 36107, "uses features that are not available in
// '<stage>' stage") even though every backend has the underlying `discard`.
//
// `sc2_clip` keeps `clip` on the D3D targets — the DXBC the validation harness
// checks against the retail `.fx` compile stays byte-for-byte what it was — and
// falls back to the equivalent guarded `discard` everywhere else.  The two are
// NOT interchangeable at the bytecode level: fxc schedules an explicit
// `if (x < 0) discard;` differently from the intrinsic (same `lt` + `discard_nz`
// pair, different register allocation around it), so the `__target_switch` is
// load-bearing, not stylistic.
//
// HLSL `clip` takes the component-wise view — ANY negative component kills the
// fragment — so the vector overloads test with `any(v < 0)`.

implementing sc2_shaders;

void sc2_clip(float x)
{
    __target_switch
    {
    case hlsl:  clip(x);                 break;
    default:    if (x < 0) discard;      break;
    }
}

void sc2_clip(float2 v)
{
    __target_switch
    {
    case hlsl:  clip(v);                 break;
    default:    if (any(v < 0)) discard; break;
    }
}

void sc2_clip(float3 v)
{
    __target_switch
    {
    case hlsl:  clip(v);                 break;
    default:    if (any(v < 0)) discard; break;
    }
}

void sc2_clip(float4 v)
{
    __target_switch
    {
    case hlsl:  clip(v);                 break;
    default:    if (any(v < 0)) discard; break;
    }
}
