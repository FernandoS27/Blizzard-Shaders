// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// CMAA pass 3 of 4 — COMBINE EDGES / DETECT SHAPE CANDIDATES
// (ffxcmaaedgecombine).
//
// Intel CMAA 1.x `combineEdges` / shape-candidate detection. Single-permutation
// full-screen pass at HALF resolution. Gathers the refined per-texel edge flags
// from pass 2 across the 2x2 quad and its neighbours, and assembles, for each
// quad texel, the full 4-direction edge mask. The mask bit layout matches the
// reference (`UnpackEdge`):
//
//     bit 0 (0x01) = Right    bit 1 (0x02) = Above
//     bit 2 (0x04) = Left     bit 3 (0x08) = Below
//
// An edge between two texels is owned by one of them, so each texel's mask ORs
// in the relevant edge bit of its neighbour on the far side. The combined mask
// is scattered to u_cmaaCombined; a texel whose mask has more than one bit
// (countbits > 1 — i.e. a corner/L/Z, not a straight edge) is a shape
// candidate, and oDepth/stencil is set to 1.0 wherever the quad contains any
// candidate so the final pass only runs there.
//
// Pass 2 wrote the same scalar to all four channels of the refined-edge
// texture, so every Gather/Load here returns that value regardless of channel;
// only the *spatial* footprint ordering matters. This is a faithful
// transcription of re_shaders/cmaa/ffxcmaaedgecombine/perm_000.asm — including
// the bit assembly — with the centre Load offset (1,1) that the decompiled
// HLSL had dropped restored from the disassembly.

implementing wc3_shaders;

[shader("fragment")]
public CmaaDepthOnlyPSOutput cmaa_edge_combine_ps_main(CmaaPSInput input)
{
    CmaaDepthOnlyPSOutput output;

    int4 r0   = (int4)input.svPosition.xyyy;        // (px, py, py, py)
    int2 base = (int2)((uint2)int2(r0.x, r0.w) << 1);
    float2 uv = cmaaPsCB0.invTargetSize * (float2)base;

    // Two Gather taps collect the refined-edge bytes of the quad + neighbours.
    // Decode unorm8 → signed edge code via (*255 - 127.5).
    float3 gA = t_cmaaEdges.Gather(s_cmaaPoint, uv, int2(0, 1)).xyw;
    float4 gB = t_cmaaEdges.Gather(s_cmaaPoint, uv, int2(1, 0));

    uint4 dB = (uint4)(gB.wzxy * 255.0 - 127.5);     // 4 decoded texels (E gather)
    float3 dA = gA.zxy * 255.0 - 127.5;              // 3 decoded texels (S gather)
    uint3 a   = (uint3)dA.xzy;                       // -> r3.yzw lanes

    // Assemble the per-texel mask lanes exactly as the shipped shader does.
    uint r3x = dB.z;
    uint r3y = a.x;
    uint r3z = a.y;
    uint r3w = a.z;

    // Bit 2 (0x04 = Left) contribution: bit0 of (r3.y, r3.x, r3.w, r3.z) << 2.
    uint4 r4 = (uint4(r3y, r3x, r3w, r3z) & 1u) << 2;

    // Centre texel's own refined edge (base + (1,1)); all channels equal.
    float ld = t_cmaaEdges.Load(int3(base + int2(1, 1), 0)).x * 255.0 - 127.5;
    r3w = (uint)ld;          // overwrites lane w
    r3y = dB.w;              // overwrites lane y

    // Bit 3 (0x08 = Below, value 8) contribution from bit1 of the right-gather codes.
    uint4 r2 = (dB << 2) & 8u;
    uint4 r3 = r4 | uint4(r3x, r3y, r3z, r3w);
    uint4 mask = r2 | r3;                            // 4 combined direction masks

    // Shape candidate where a mask has >1 edge bit. oDepth = 1.0 if any.
    bool4 candidate = countbits(mask) > 1u;
    output.depth = any(candidate) ? 1.0 : 0.0;

    // Scatter the masks (as mask/255) to the four quad-texel positions.
    float4 store = (float4)mask * 0.00392156886;
    u_cmaaCombined[uint2(base + int2(0, 0))] = store.x.xxxx;
    u_cmaaCombined[uint2(base + int2(1, 0))] = store.y.xxxx;
    u_cmaaCombined[uint2(base + int2(0, 1))] = store.z.xxxx;
    u_cmaaCombined[uint2(base + int2(1, 1))] = store.w.xxxx;

    return output;
}
