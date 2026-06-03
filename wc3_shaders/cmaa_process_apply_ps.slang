// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// CMAA pass 4 of 4 — PROCESS CANDIDATES AND APPLY (ffxcmaaprocessandapply).
//
// Intel CMAA 1.x `BlurEdges` (the `blur` program in the reference). Single-
// permutation full-screen pass at HALF resolution; each invocation handles a
// 2x2 quad. For every quad texel it:
//
//   A) SIMPLE SHAPES (Intel CMAA "simple shape handling"): reads the texel's
//      combined 4-direction edge mask, and if it has >= 2 edges blends the texel
//      toward the weighted average of its edge-side neighbours by a `blurCoeff`
//      chosen from `numberOfEdges`. The blended colour is written to u_cmaaColor.
//
//   B) Z/L LARGE-SHAPE DETECTION (Intel CMAA `large_l1..4` / `isolated_l1..4`):
//      a 2-edge texel that forms an L/Z corner continuing into a neighbour is
//      NOT simple-blurred; instead its coord + orientation is queued (x0[4]) for
//      symmetrical long-edge handling.
//
//   C) SYMMETRICAL LONG-EDGE HANDLING: each queued candidate is walked along its
//      edge up to `c_maxLineLength` (= 64) texels in each direction to measure
//      the run; the source colour is then linearly re-sampled at a sub-texel
//      offset along a smooth slope (`leftOdd`/`rightOdd` symmetry dampening of
//      0.15) and written back, replacing the staircase with a smooth edge.
//
// BLUR RETUNE — the one place Warcraft III Reforged differs from stock Intel
// CMAA 1.x: the simple-shape blur coefficients are reduced for a sharper, less
// invasive result (the surrounding `(1 - opp)(1 - opp)` structure is unchanged):
//
//     numberOfEdges   Intel CMAA 1.x   Reforged (this shader)
//        2 (L/Z)           0.15              0.08
//        3 (U)             0.13              0.11
//        4 (enclosed)      0.07              0.05
//
// Reference: Intel CMAA (Filip Strugar, 2014) — `BlurEdges`, `FindLineLength`.
// Faithful reconstruction of ffxcmaaprocessandapply.bls: the simple-shape
// blend, junction tests, and trace loop follow
// re_shaders/cmaa/ffxcmaaprocessandapply/perm_000.asm exactly; the per-load
// neighbour offsets and store_uav scatters (dropped by the decompiler) were
// recovered from that disassembly. Comparison results are carried as int (-1/0)
// so the bitwise large-shape math round-trips identically. The large-shape
// detection in the shipped DXBC reuses some leftover/path-dependent register
// lanes (fxc artifacts of compiling the reference's `large_l/isolated` logic);
// those are reconstructed deterministically and documented at each call site.

implementing wc3_shaders;

// Comparison → integer mask (-1 = true, 0 = false), matching DXBC compare ops
// so bitwise AND/OR over comparison results behaves exactly as in the bytecode.
int  cmpi(bool b)  { return b ? -1 : 0; }
int2 cmpi(bool2 b) { return select(b, int2(-1, -1), int2(0, 0)); }
int3 cmpi(bool3 b) { return select(b, int3(-1, -1, -1), int3(0, 0, 0)); }
int4 cmpi(bool4 b) { return select(b, int4(-1, -1, -1, -1), int4(0, 0, 0, 0)); }

// Edge-presence bits of a 4-direction mask (1/0), in Intel CMAA `UnpackEdge`
// order: .x = Right (0x01), .y = Above (0x02), .z = Left (0x04), .w = Below (0x08).
int4 cmaaDirBits(int mask)
{
    return select((int4(mask, mask, mask, mask) & int4(1, 2, 4, 8)) != 0,
                  int4(1, 1, 1, 1), int4(0, 0, 0, 0));
}

// Simple-shape `blurCoeff` (Intel CMAA). `dirsR` is `cmaaDirBits` reordered
// (.zwxy) as the shipped shader keeps it. For the 2-edge case the base is scaled
// by the absence of opposite-edge pairs — `(1 - oppV)(1 - oppH)` — so a straight
// edge (two opposite edges) gets 0 and only true corners blur. The 3/4-edge
// cases use fixed values. NOTE the Reforged retune: 0.08/0.11/0.05 where stock
// Intel CMAA uses 0.15/0.13/0.07 (see header).
float cmaaBlurWeight(float4 dirsR, float count)
{
    float w = (1.0 - dirsR.w * dirsR.y) * (1.0 - dirsR.z * dirsR.x) * 0.0799999982;
    if (count > 2.0) w = 0.109999999;     // numberOfEdges == 3  (Intel 0.13)
    if (count > 3.0) w = 0.0500000007;    // numberOfEdges == 4  (Intel 0.07)
    return w;
}

// Blend a texel toward the weighted average of its 4 edge-side neighbours and
// store it. `wt` is the per-direction blur weight (dir bits * blurCoeff); the
// lanes weight the left (-1,0) / up (0,-1) / right (1,0) / down (0,1) neighbours.
// Mirrors Intel CMAA's `color /= weightSum + 0.0001` then lerp toward centre by
// `centerWeight/allWeightSum` (here `1 - 1/(1+sumw)`).
void cmaaSimpleBlendStore(int2 coord, float4 wt)
{
    float4 center = t_cmaaColor.Load(int3(coord, 0));
    float sumw = wt.x + wt.y + wt.z + wt.w;
    float3 accum = wt.x * t_cmaaColor.Load(int3(coord + int2(-1, 0), 0)).xyz   // left
                 + wt.y * t_cmaaColor.Load(int3(coord + int2(0, -1), 0)).xyz   // up
                 + wt.z * t_cmaaColor.Load(int3(coord + int2(1, 0), 0)).xyz    // right
                 + wt.w * t_cmaaColor.Load(int3(coord + int2(0, 1), 0)).xyz;   // down
    float3 avg = accum / (sumw + 9.99999975e-05);
    float blend = 1.0 - 1.0 / (1.0 + sumw);
    float3 outRGB = center.xyz + blend * (avg - center.xyz);
    u_cmaaColor[uint2(coord)] = float4(outRGB, center.w);   // keep source alpha
}

// Read a combined-edge mask from t_cmaaEdges (all channels equal; decode the
// unorm8 byte via *255.5, matching the reference's `* 255.5` reads).
uint cmaaLoadMask(int2 coord)
{
    return (uint)(t_cmaaEdges.Load(int3(coord, 0)).x * 255.5);
}

// Edge-presence bits of an int value (same as cmaaDirBits; used on dir records).
int4 cmaaBitsOf(int v)
{
    return select((int4(v, v, v, v) & int4(1, 2, 4, 8)) != 0,
                  int4(1, 1, 1, 1), int4(0, 0, 0, 0));
}

// Large-shape (Z/L) continuation test, shared across the four texels. This is
// the bitwise core of Intel CMAA's `large_l1..4` / `isolated_l1..4` checks plus
// the neighbour-continuation product: given the texel's edge bits (b6), the
// chosen orientation `sel`, and the direction record `dir` (.z/.w = continuation
// masks toward the two arms, .xy = neighbour offset), it samples the
// continuation neighbour and multiplies together all the per-arm conditions.
// Returns true (with the orientation bits in `orient`) when the corner is part
// of a longer shape and the candidate should be queued for the long-edge pass.
// Mirrors the imul-reduction in
// re_shaders/cmaa/ffxcmaaprocessandapply/perm_000.asm.
bool cmaaJunctionConfirm(int4 b6, int sel, int4 dir, int2 texel, out float2 orient)
{
    int4 d9  = cmaaBitsOf(dir.z);
    int4 d10 = cmaaBitsOf(dir.w);
    uint nb  = cmaaLoadMask(texel + dir.xy);
    int4 d8  = select((int4(nb, nb, nb, nb).ywxz & int4(1, 2, 4, 8)) != 0,
                      int4(1, 1, 1, 1), int4(0, 0, 0, 0));

    int4 r6  = (sel != 0) ? b6 : b6.wxyz;
    int3 r10 = (sel != 0) ? d10.xyw : d10.wxz;
    int4 r8  = (sel != 0) ? int4(d9.y, d9.w, d8.x, d8.y) : int4(d9.x, d9.z, d8.z, d8.w);

    int2 p = int2(r6.y * r6.x, r6.w * r6.x);
    p = int2(r8.x, r8.y) * p;
    p = int2(r10.z, r10.y) * p;
    p = int2(r8.w, r8.z) * p;
    int3 inv6 = int3(1, 1, 1) - int3(r6.z, r6.w, r6.y);
    p = p * int2(inv6.x, inv6.x);
    int3 inv10 = int3(1, 1, 1) - r10;
    p = p * int2(inv10.x, inv10.x);
    p = int2(inv6.y, inv6.z) * p;
    p = int2(inv10.y, inv10.z) * p;

    int2 pos = cmpi(int2(0, 0) < p);
    orient = float2(sel & 1, pos.x & 1);
    return (pos.y | pos.x) != 0;
}

[shader("fragment")]
[earlydepthstencil]
public void cmaa_process_apply_ps_main(CmaaPSInput input)
{
    float4 x0[4];

    int2 base = (int2)((uint2)(int2)input.svPosition.xy << 1);
    float2 uv = cmaaPsCB0.invTargetSize * (float2)base;

    // Four Gather taps decode the 4x4 neighbourhood of combined-edge masks.
    int3 g2; { float3 G = t_cmaaEdges.Gather(s_cmaaPoint, uv).xyz * 255.5;            g2 = (int3)G.xzy; }
    int4 g3; { float3 G = t_cmaaEdges.Gather(s_cmaaPoint, uv, int2(2, 0)).xyw * 255.5; g3.x = (int)G.y; g3.y = (int)G.z; g3.w = (int)G.x; g3.z = 0; }
    int3 g4; { float3 G = t_cmaaEdges.Gather(s_cmaaPoint, uv, int2(0, 2)).yzw * 255.5; g4 = (int3)G.xzy; }
    int3 g1; { float3 G = t_cmaaEdges.Gather(s_cmaaPoint, uv, int2(2, 2)).xzw * 255.5; g1 = (int3)G; }

    int queue = 0;

    // The four quad texels share the same structure: compute the texel's edge
    // mask, blur it if it forms a >=2-edge simple shape, and (for exact 2-edge
    // L/Z corners) test whether the shape continues and queue it for tracing.
    //
    // The shipped DXBC's junction queueing reuses leftover/path-dependent
    // register lanes in places (it reads lanes last written by the texel-0
    // dir-bit setup, or retained Gather lanes). Those values are reconstructed
    // deterministically below from the texel-0 mask (g2.z) / retained Gather
    // lanes. In the rare degenerate case where a texel matches two corner
    // patterns at once AND a prior texel also queued, the queue decision can
    // differ from the shipped shader. The simple-shape blur (the dominant CMAA
    // effect) and the long-edge trace are exact.

    // ============================ TEXEL 0 (base+(0,0)) ============================
    {
        int mask = g2.z;
        int4 b6 = cmaaDirBits(mask);
        float4 dirsR = float4(b6.zwxy);
        float count = float(b6.x + b6.y + b6.z + b6.w);
        if (count >= 2.0)
        {
            float w = cmaaBlurWeight(dirsR, count);
            if (w != 0.0)
            {
                cmaaSimpleBlendStore(base, dirsR * w);
                if (count == 2.0)
                {
                    int3 c = cmpi(int3(mask, mask, mask) == int3(3, 9, 12));
                    int2 r5 = cmpi((int2(g3.w, g3.w) & int2(9, 3)) == int2(8, 2)) & c.xy;
                    int t1 = r5.y | r5.x;
                    int2 e = cmpi((int2(g2.y, g2.y) & int2(12, 9)) == int2(4, 1)) & c.yz;
                    int t2 = e.y | e.x;
                    if ((t1 | t2) != 0)
                    {
                        int both = t1 & t2;
                        int2 g = cmpi((int2(g2.x, g2.x) & int2(2, 8)) == int2(2, 8));
                        r5 = r5 & g;
                        int sel = (both != 0) ? (r5.y | r5.x) : t1;
                        int4 dir = (sel != 0) ? int4(2, 0, g2.x, g3.w) : int4(0, -2, g4.z, g2.y);
                        float2 orient;
                        if (cmaaJunctionConfirm(b6, sel, dir, base, orient))
                        {
                            x0[queue] = float4((float2)base, orient);
                            queue += 1;
                        }
                    }
                }
            }
        }
    }

    // ============================ TEXEL 1 (base+(1,0)) ============================
    {
        int mask = g3.w;
        int4 b6 = cmaaDirBits(mask);
        float4 dirsR = float4(b6.zwxy);
        float count = float(b6.x + b6.y + b6.z + b6.w);
        if (count >= 2.0)
        {
            float w = cmaaBlurWeight(dirsR, count);
            if (w != 0.0)
            {
                int2 texel = base + int2(1, 0);
                cmaaSimpleBlendStore(texel, dirsR * w);
                if (count == 2.0)
                {
                    int4 c = cmpi(int4(mask, mask, mask, mask) == int4(3, 9, 9, 12));
                    int4 m = cmpi((int4(g3.x, g3.x, g3.y, g3.y) & int4(9, 3, 12, 9)) == int4(8, 2, 4, 1)) & c;
                    int r5x = m.y | m.x;
                    int r5z = m.w | m.z;
                    if ((r5z | r5x) != 0)
                    {
                        int both = r5z & r5x;
                        // r5.y/r5.w retain the texel-0 dir bits (g2.z & 2 / & 8).
                        int ry = cmpi((g2.z & 2) == 2) & m.x;
                        int rz = cmpi((g2.z & 8) == 8) & m.y;
                        int sel = (both != 0) ? (rz | ry) : r5x;
                        int4 dir = (sel != 0) ? int4(2, 0, g2.z, g3.x) : int4(0, -2, g1.z, g3.y);
                        float2 orient;
                        if (cmaaJunctionConfirm(b6, sel, dir, texel, orient))
                        {
                            x0[queue] = float4((float2)texel, orient);
                            queue += 1;
                        }
                    }
                }
            }
        }
    }

    // ============================ TEXEL 2 (base+(0,1)) ============================
    {
        int mask = g4.z;
        int4 b6 = cmaaDirBits(mask);
        float4 dirsR = float4(b6.zwxy);
        float count = float(b6.x + b6.y + b6.z + b6.w);
        if (count >= 2.0)
        {
            float w = cmaaBlurWeight(dirsR, count);
            if (w != 0.0)
            {
                int2 texel = base + int2(0, 1);
                cmaaSimpleBlendStore(texel, dirsR * w);
                if (count == 2.0)
                {
                    int3 c = cmpi(int3(mask, mask, mask) == int3(3, 9, 12));
                    int2 r5 = cmpi((int2(g1.z, g1.z) & int2(9, 3)) == int2(8, 2)) & c.xy;
                    int t1 = r5.y | r5.x;
                    int2 e = cmpi((int2(g2.z, g2.z) & int2(12, 9)) == int2(4, 1)) & c.yz;
                    int t2 = e.y | e.x;
                    if ((t1 | t2) != 0)
                    {
                        int both = t1 & t2;
                        int2 g = cmpi((int2(g4.y, g4.y) & int2(2, 8)) == int2(2, 8));
                        r5 = r5 & g;
                        int sel = (both != 0) ? (r5.y | r5.x) : t1;
                        // non-dominant continuation lane is path-dependent in the
                        // shipped DXBC; 0 here (conservative -- no continuation).
                        int4 dir = (sel != 0) ? int4(2, 0, g4.y, g1.z) : int4(0, -2, g4.x, 0);
                        float2 orient;
                        if (cmaaJunctionConfirm(b6, sel, dir, texel, orient))
                        {
                            x0[queue] = float4((float2)texel, orient);
                            queue += 1;
                        }
                    }
                }
            }
        }
    }

    // ============================ TEXEL 3 (base+(1,1)) ============================
    {
        int mask = g1.z;
        int4 b6 = cmaaDirBits(mask);
        float4 dirsR = float4(b6.zwxy);
        float count = float(b6.x + b6.y + b6.z + b6.w);
        if (count >= 2.0)
        {
            float w = cmaaBlurWeight(dirsR, count);
            if (w != 0.0)
            {
                int2 texel = base + int2(1, 1);
                cmaaSimpleBlendStore(texel, dirsR * w);
                if (count == 2.0)
                {
                    int3 c = cmpi(int3(mask, mask, mask) == int3(3, 9, 12));
                    int2 r1 = cmpi((int2(g1.y, g1.y) & int2(9, 3)) == int2(8, 2)) & c.xy;
                    int t1 = r1.y | r1.x;
                    int2 e = cmpi((int2(g3.w, g3.w) & int2(12, 9)) == int2(4, 1)) & c.yz;
                    int t2 = e.y | e.x;
                    if ((t1 | t2) != 0)
                    {
                        int both = t1 & t2;
                        // r5.y/r5.w leftover -> texel-0 dir bits (g2.z & 2 / & 8).
                        int ry = cmpi((g2.z & 2) == 2) & r1.x;
                        int rz = cmpi((g2.z & 8) == 8) & r1.y;
                        int sel = (both != 0) ? (rz | ry) : t1;
                        // dir.z (sel) = retained g4.z; dir.w (non-sel) = retained g3.w.
                        int4 dir = (sel != 0) ? int4(2, 0, g4.z, g1.y) : int4(0, -2, g1.x, g3.w);
                        float2 orient;
                        if (cmaaJunctionConfirm(b6, sel, dir, texel, orient))
                        {
                            x0[queue] = float4((float2)texel, orient);
                            queue += 1;
                        }
                    }
                }
            }
        }
    }

    // ===================== STAGE C: SYMMETRICAL LONG-EDGE HANDLING =====================
    // For each queued L/Z candidate: trace its edge in both directions to find
    // the line length, then re-sample every pixel along the run at a sub-texel
    // offset on a smooth slope. Mirrors Intel CMAA `FindLineLength` + the line
    // blend loop. The blend amount is `m = saturate((i + 0.5 - leftOdd - loopFrom)
    // / totalLength)`, with the 0.15 odd-length symmetry dampening.
    const uint c_maxLineLength = 64u;        // Intel CMAA `c_maxLineLength`

    float2 texSize;
    t_cmaaColor.GetDimensions(texSize.x, texSize.y);
    float2 invSize = 1.0 / texSize;

    for (int wi = 0; wi < queue; wi++)
    {
        float4 cand = x0[wi];
        int2 cCoord = (int2)cand.xy;          // candidate texel
        bool horizontal = cand.z != 0.0;      // shape orientation (z arm)
        bool invertedZ  = cand.w != 0.0;      // Z inversion (mirrors blend sign)

        // Direction tables selected by orientation: stepDir walks the edge,
        // stopMask/traceMask drive the run-length search (Intel CMAA's
        // maskTrace*/maskStop* per horizontal/vertical case).
        int4 stepTbl   = horizontal ? int4(1, 0, 0, -1) : int4(0, -1, -1, 0);
        int4 mtab      = invertedZ  ? int4(2, 8, 1, 4) : int4(8, 2, 4, 1);
        int4 traceMask = horizontal ? int4(mtab.x, mtab.y, 1, 4) : int4(mtab.z, mtab.w, 8, 2);
        int2 stopMask  = int2(traceMask.z | traceMask.x, traceMask.w | traceMask.y);
        int2 stepDir   = horizontal ? int2(-1, 0) : int2(0, 1);

        // --- FindLineLength: advance until the edge stops or turns ---
        int3 trace = int3(0, 0, 2);           // .z = step index, .xy = stop offsets
        int found = 0;
        [loop] while (true)
        {
            if ((uint)trace.z >= c_maxLineLength) { found = 0; break; }
            uint edgeStop  = cmaaLoadMask(stepDir * trace.z + cCoord);
            int  next      = trace.z + 1;
            uint edgeTrace = cmaaLoadMask(stepTbl.xy * next + cCoord);
            int2 masked    = stopMask & int2((int)edgeStop, (int)edgeTrace);
            int2 stopped   = cmpi(int2(traceMask.x, traceMask.y) != masked);
            if ((stopped.y | stopped.x) != 0) { trace.xy = stopped + next; found = -1; break; }
            trace = int3(0, 0, next);
            found = stopped.x;                 // = 0; continue
        }

        // --- run length + odd-length symmetry dampening (leftOdd/rightOdd = 0.15*(len%2)) ---
        int2 lineLen   = (found != 0) ? trace.xy : int2(trace.z, trace.z);
        float2 oddBits = (float2)(lineLen & int2(1, 1));   // (lineLengthLeft%2, lineLengthRight%2)
        lineLen = (lineLen + int2(1, 1)) >> 1;
        int loopFrom   = 1 - lineLen.x;
        int loopTo     = lineLen.y;
        float leftOdd  = oddBits.x * 0.150000006;
        float rightOdd = oddBits.y * 0.150000006;
        float totalLength = (float)(loopTo - loopFrom) + 1.0 - leftOdd - rightOdd;

        // --- blend every pixel along the run, re-sampling on the smooth slope ---
        [loop] for (int i = loopFrom; i <= loopTo; i++)
        {
            int4 pp = stepTbl.xyyy * i + int4(cCoord.x, cCoord.y, cCoord.y, cCoord.y);
            float2 tap = (float2)int2(pp.x, pp.w) + 0.5;
            float m = (float)i - leftOdd - (float)loopFrom + 0.5;
            m = saturate(m / totalLength);
            m = m + ((0 < i) ? -1.0 : -0.0);   // shift so the ramp straddles the line
            m = invertedZ ? -m : m;
            tap = (float2)stepTbl.zw * m + tap;
            tap = invSize * tap;
            float4 col = t_cmaaColor.SampleLevel(s_cmaaLinear, tap, 0.0);
            u_cmaaColor[uint2(int2(pp.x, pp.w))] = col;
        }
    }
}
