// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Bokeh depth-of-field pixel shader (depthoffield.bls).
//
// One full-screen permutation implementing the "Bokeh depth of field in a
// single pass" technique by Dennis Gustafsson (blog.tuxedolabs.com, 2018).
// The bokeh disc is walked along a Fermat / Vogel ("sunflower") spiral: the
// sample angle advances by the golden angle (2.39996 rad = 137.5 deg) every
// step while the radius grows by `radiusScale / radius`. Because
// r_{n+1} = r_n + k / r_n integrates to r ~ sqrt(n), the taps spread at a
// roughly uniform area density across the disc with no precomputed sample
// table.
//
// Algorithm (per fragment):
//   centerCoC  = clamp((1/focus - 1/centerDepth) * focusScale, -1, 1)
//   accum      = centerColor;  count = 1
//   for (radius = radiusScale; radius < maxBlurSize; radius += radiusScale/radius)
//       tap        = uv + radius * (cos a, sin a) * texelSize
//       sampleSize = |coc(tapDepth)| * maxBlurSize          // neighbour blur radius
//       if (tap is behind center) sampleSize <= 2 * centerSize   // bleed guard
//       w          = smoothstep(radius - 0.5, radius + 0.5, sampleSize)
//       accum     += lerp(accum / count, tapColor, w);  ++count
//   return accum / count
//
// Faithful reconstruction of war3.w3mod/shaders/ps/depthoffield.bls — see
// re_shaders/depthoffield/perm_000.{asm,hlsl}. The hyperbolic CoC term, the
// signed near/far encoding, the behind-focus bleed clamp to 2*centerSize, the
// hard disc gate layered in front of the smoothstep, and the running-average
// blend order all mirror the shipped DXBC. The body reconstructs the UV from
// `SV_Position` and never reads the interpolated TEXCOORD0, exactly as the
// shipped shader does (it is declared on `SpritePSInput` only so the ISGN
// matches). The optional far-field-only flag (cb1[2].w) is a Warcraft addition
// over the reference, clamping the CoC positive to suppress foreground blur.

implementing wc3_shaders;

// Golden angle (137.5 deg) in radians; matches the shipped literal 2.39996314.
static const float GOLDEN_ANGLE = 2.39996314;
// Sentinel substituted for depth == 0 (sky / cleared depth) so it sorts as far.
static const float FAR_DEPTH = 10000.0;
// Lower bound applied to the CoC in far-field-only mode; the shipped DXBC uses
// 0.00999999978 (i.e. 0.01f).
static const float MIN_COC = 0.01;

// Signed circle of confusion in [-1, 1] for a linear depth, per the thin-lens
// model. Negative is near field (in front of focus), positive is far field.
float dofCircleOfConfusion(float depth, float invFocusDistance, float focusScale)
{
    float coc = (invFocusDistance - 1.0 / depth) * focusScale;
    return clamp(coc, -1.0, 1.0);
}

// Scene depth fetch with the sky sentinel applied.
float dofSampleDepth(float2 uv)
{
    float depth = t_dofDepth.Sample(s_dofDepth, uv).x;
    return depth == 0.0 ? FAR_DEPTH : depth;
}

[shader("fragment")]
public float4 depth_of_field_ps_main(SpritePSInput input) : SV_Target0
{
    const float2 texelSize    = depthOfFieldPsCB1.invResolution;
    const float  maxBlurSize  = depthOfFieldPsCB1.maxBlurSize;
    const float  radiusScale  = depthOfFieldPsCB1.radiusScale;
    const float  focusScale   = depthOfFieldPsCB1.focusScale;
    const float  invFocus     = 1.0 / depthOfFieldPsCB1.focusDistance;
    const bool   farFieldOnly = depthOfFieldPsCB1.farFieldOnly == 1.0;

    // Center UV is rebuilt from pixel coordinates, not the TEXCOORD0 input.
    float2 centerUv = texelSize * input.svPosition.xy;

    float centerDepth = dofSampleDepth(centerUv);
    float centerCoc = dofCircleOfConfusion(centerDepth, invFocus, focusScale);
    if (farFieldOnly) {
        centerCoc = max(MIN_COC, centerCoc);
    }

    // A neighbour behind the focus plane may blur at most twice the center's
    // blur size, so a sharp far background cannot bleed over a focused subject.
    float maxSampleSize = 2.0 * abs(centerCoc) * maxBlurSize;

    // Accumulator seeded with the center tap (count == 1).
    float3 accumColor  = t_dofColor.Sample(s_dofColor, centerUv).xyz;
    float  sampleCount = 1.0;

    // Walk the bokeh disc along the golden-angle spiral.
    float radius = radiusScale;
    float angle  = 0.0;
    while (radius < maxBlurSize)
    {
        // Spiral tap: offset = radius * (cos, sin), converted to UV.
        float sinA, cosA;
        sincos(angle, sinA, cosA);
        float2 offset   = float2(cosA, sinA) * radius;
        float2 sampleUv = offset * texelSize + centerUv;

        float3 sampleColor = t_dofColor.Sample(s_dofColor, sampleUv).xyz;

        float sampleDepth = dofSampleDepth(sampleUv);
        float sampleCoc = dofCircleOfConfusion(sampleDepth, invFocus, focusScale);
        if (farFieldOnly) {
            sampleCoc = max(MIN_COC, sampleCoc);
        }

        // Neighbour blur radius in pixels, with the behind-focus bleed guard.
        float sampleSize = maxBlurSize * abs(sampleCoc);
        if (centerDepth < sampleDepth) {
            sampleSize = min(max(0.0, sampleSize), maxSampleSize);
        }

        // Hard disc gate: the neighbour contributes only if its blur disc
        // reaches this pixel, i.e. radius <= sampleSize (|offset| / size <= 1).
        float discDist = length(offset / sampleSize);
        if (!(discDist >= 0.0 && discDist <= 1.0)) {
            sampleSize = 0.0;
        }

        // Soft disc edge, then Gustafsson's running-average blend.
        float weight = smoothstep(radius - 0.5, radius + 0.5, sampleSize);
        accumColor += lerp(accumColor / sampleCount, sampleColor, weight);
        sampleCount += 1.0;

        // Advance the spiral (radius ~ sqrt(n) thanks to the radius/r step).
        radius += radiusScale / radius;
        angle  += GOLDEN_ANGLE;
    }

    return float4(accumColor / sampleCount, 1.0);
}
