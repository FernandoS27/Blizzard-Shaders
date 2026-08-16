// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Simple family pixel shader (simple.fx : SimplePixelMain).
//
// cResult = sample(p_sTexture, vUV) * cColor, then the engine's AlphaTest:
//   common.fx: if (b_iAlphaTest) clip(cResult.a - p_fAlphaThreshold);
//
// The single compile-time axis, b_iAlphaTest, is passed as a preprocessor
// define (matching wc3_shaders' pattern: `-Db_iAlphaTest=1` when on, define
// absent when off).  The decode maps it from key byte 15 bit 0x80
// (tools/sc2_family_decode.py).

implementing sc2_shaders;

[shader("fragment")]
public float4 simple_ps_main(SimplePSInput input) : SV_Target
{
    float4 cResult = p_sTexture_t.Sample(p_sTexture_s, input.vUV.xy) * input.cColor;
#if b_iAlphaTest
    clip(cResult.a - p_fAlphaThreshold);
#endif
    return cResult;
}
