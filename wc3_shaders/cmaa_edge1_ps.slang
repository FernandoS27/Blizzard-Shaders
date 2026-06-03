// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// CMAA pass 2 of 4 — LOCAL CONTRAST ADAPTATION / NON-DOMINANT EDGE REMOVAL
// (ffxcmaaedge1).
//
// This is Intel CMAA 1.x `PruneNonDominantEdges` (the `edge2` program in the
// reference). Single-permutation full-screen pass at HALF resolution. Reads the
// packed per-quad edge bytes from pass 1 (t_cmaaEdgesPacked: a uint4 where each
// channel is one quad texel's `right | (down << 4)` strength byte) and, for
// every texel carrying an edge, keeps that edge only if its strength stands out
// against the strongest contrast in its immediate neighbourhood:
//
//     threshold = avg * 0.65 + maxE * 0.35
//
//   - `maxE` is the max edge strength over the ~12-edge local neighbourhood;
//   - `avg`  is the mean of one collected 4-edge group. (In the reference
//     `PruneNonDominantEdges` the `avg = dot(edges[i], 1/12)` assignment inside
//     the collect loop only retains the last group — this shader reproduces
//     that exactly, hence the single 4-element `avgSet` per texel below.)
//
//     keepRight = strengthRight >= threshold ;  keepDown = strengthDown >= threshold
//
// The surviving 1-bit flags are packed `right | (down << 1)`, tagged with the
// +128 "processed" high bit (the reference's shapeType byte lives in the high
// nibble), and stored as unorm8 to u_cmaaEdgesRefined at the full-res texel.
//
// Reference: Intel CMAA (Filip Strugar, 2014) — `PruneNonDominantEdges`,
// `UnpackThresholds`. Faithful reconstruction of ffxcmaaedge1.bls: the shipped
// shader caches neighbour-quad bytes in an indexable temp guarded by per-side
// prefetch tests; reading the neighbour bytes directly here is functionally
// identical (a texel is only processed when its own byte is non-zero, exactly
// when the prefetch guards fire, and OOB Loads return 0 in both forms).
// Verified against re_shaders/cmaa/ffxcmaaedge1/perm_000.asm.

implementing wc3_shaders;

// Unpack a packed byte's two 4-bit edge strengths to [0,1] (Intel CMAA
// `UnpackThresholds`: vec2(val & 0x0F, val >> 4) / 15). The low nibble is the
// RIGHT (horizontal) edge, the high nibble the DOWN (vertical) edge.
float cmaaUnpackH(uint b) { return (b & 15u) * 0.0666666701; }   // right / horizontal
float cmaaUnpackV(uint b) { return (b >> 4) * 0.0666666701; }   // down  / vertical

// Non-dominant-edge threshold (Intel CMAA: `avg * 0.65 + maxE * 0.35`). avgSet
// is the collected 4-edge group whose mean is `avg`; maxNeighbour is `maxE`.
float cmaaLocalThreshold(float4 avgSet, float maxNeighbour)
{
    float avg = dot(avgSet, float4(0.0833333358, 0.0833333358, 0.0833333358, 0.0833333358));
    return avg * 0.649999976 + maxNeighbour * 0.349999994;
}

// Keep the own right/down edges that beat the threshold; pack `right | (down<<1)`
// into [0..3] (0 if neither survives).
int cmaaKeepFlags(float2 ownStrength, float threshold)
{
    int keepRight = (ownStrength.x >= threshold) ? 1 : 0;
    int keepDown  = (ownStrength.y >= threshold) ? 1 : 0;
    return keepRight | (keepDown << 1);
}

// Write a surviving flag byte as unorm8 (+128 processed bit) at a texel.
void cmaaStoreRefined(int flags, int2 coord)
{
    if (flags != 0)
        u_cmaaEdgesRefined[uint2(coord)] = (((float)(flags + 128)) * 0.00392156886).xxxx;
}

[shader("fragment")]
[earlydepthstencil]
public void cmaa_edge1_ps_main(CmaaPSInput input)
{
    int2 quad = (int2)(uint2)input.svPosition.xy;
    int2 base = quad << 1;                       // full-res top-left of the quad

    // This quad's four packed edge bytes: p0=(0,0) p1=(1,0) p2=(0,1) p3=(1,1).
    uint4 q = t_cmaaEdgesPacked.Load(int3(quad, 0));
    uint p0 = q.x, p1 = q.y, p2 = q.z, p3 = q.w;

    // Neighbour-quad bytes (the channel picks the neighbour texel adjacent to
    // this quad; OOB Loads return 0). Names are the absolute texel each holds.
    uint p2_above  = t_cmaaEdgesPacked.Load(int3(quad + int2(0, -1), 0)).z; // above texel0
    uint p3_above  = t_cmaaEdgesPacked.Load(int3(quad + int2(0, -1), 0)).w; // above texel1
    uint p1_left   = t_cmaaEdgesPacked.Load(int3(quad + int2(-1, 0), 0)).y; // left  texel0
    uint p3_left   = t_cmaaEdgesPacked.Load(int3(quad + int2(-1, 0), 0)).w; // left  texel2
    uint p0_right  = t_cmaaEdgesPacked.Load(int3(quad + int2(1, 0), 0)).x;  // right texel1
    uint p2_right  = t_cmaaEdgesPacked.Load(int3(quad + int2(1, 0), 0)).z;  // right texel3
    uint p0_below  = t_cmaaEdgesPacked.Load(int3(quad + int2(0, 1), 0)).x;  // below texel2
    uint p1_below  = t_cmaaEdgesPacked.Load(int3(quad + int2(0, 1), 0)).y;  // below texel3
    uint p2_abrt   = t_cmaaEdgesPacked.Load(int3(quad + int2(1, -1), 0)).z; // above-right of texel1
    uint p1_blft   = t_cmaaEdgesPacked.Load(int3(quad + int2(-1, 1), 0)).y; // below-left  of texel2

    // ----- Texel 0 (own = p0) -----
    if (p0 != 0u)
    {
        float maxN = max(max(max(cmaaUnpackH(p0), cmaaUnpackV(p0)),
                             max(cmaaUnpackH(p1), cmaaUnpackV(p1))),
                         max(max(max(cmaaUnpackH(p2), cmaaUnpackV(p2)),
                                 max(cmaaUnpackH(p1_left), cmaaUnpackV(p1_left))),
                             max(max(cmaaUnpackH(p2_above), cmaaUnpackV(p2_above)),
                                 max(cmaaUnpackV(p3_above), cmaaUnpackH(p3_left)))));
        float4 avgSet = float4(cmaaUnpackH(p2_above), cmaaUnpackV(p2_above),
                               cmaaUnpackV(p3_above), cmaaUnpackH(p3_left));
        float thr = cmaaLocalThreshold(avgSet, maxN);
        int flags = cmaaKeepFlags(float2(cmaaUnpackH(p0), cmaaUnpackV(p0)), thr);
        cmaaStoreRefined(flags, base + int2(0, 0));
    }

    // ----- Texel 1 (own = p1) -----
    if (p1 != 0u)
    {
        float maxN = max(max(max(cmaaUnpackH(p1), cmaaUnpackV(p1)),
                             max(cmaaUnpackH(p0_right), cmaaUnpackV(p0_right))),
                         max(max(max(cmaaUnpackH(p3), cmaaUnpackV(p3)),
                                 max(cmaaUnpackH(p0), cmaaUnpackV(p0))),
                             max(max(cmaaUnpackH(p3_above), cmaaUnpackV(p3_above)),
                                 max(cmaaUnpackV(p2_abrt), cmaaUnpackH(p2)))));
        float4 avgSet = float4(cmaaUnpackH(p3_above), cmaaUnpackV(p3_above),
                               cmaaUnpackV(p2_abrt), cmaaUnpackH(p2));
        float thr = cmaaLocalThreshold(avgSet, maxN);
        int flags = cmaaKeepFlags(float2(cmaaUnpackH(p1), cmaaUnpackV(p1)), thr);
        cmaaStoreRefined(flags, base + int2(1, 0));
    }

    // ----- Texel 2 (own = p2) -----
    if (p2 != 0u)
    {
        float maxN = max(max(max(cmaaUnpackH(p2), cmaaUnpackV(p2)),
                             max(cmaaUnpackH(p3), cmaaUnpackV(p3))),
                         max(max(max(cmaaUnpackH(p0_below), cmaaUnpackV(p0_below)),
                                 max(cmaaUnpackH(p3_left), cmaaUnpackV(p3_left))),
                             max(max(cmaaUnpackH(p0), cmaaUnpackV(p0)),
                                 max(cmaaUnpackV(p1), cmaaUnpackH(p1_blft)))));
        float4 avgSet = float4(cmaaUnpackH(p0), cmaaUnpackV(p0),
                               cmaaUnpackV(p1), cmaaUnpackH(p1_blft));
        float thr = cmaaLocalThreshold(avgSet, maxN);
        int flags = cmaaKeepFlags(float2(cmaaUnpackH(p2), cmaaUnpackV(p2)), thr);
        cmaaStoreRefined(flags, base + int2(0, 1));
    }

    // ----- Texel 3 (own = p3) -----
    if (p3 != 0u)
    {
        float maxN = max(max(max(cmaaUnpackH(p3), cmaaUnpackV(p3)),
                             max(cmaaUnpackH(p2_right), cmaaUnpackV(p2_right))),
                         max(max(max(cmaaUnpackH(p1_below), cmaaUnpackV(p1_below)),
                                 max(cmaaUnpackH(p2), cmaaUnpackV(p2))),
                             max(max(cmaaUnpackH(p1), cmaaUnpackV(p1)),
                                 max(cmaaUnpackV(p0_right), cmaaUnpackH(p0_below)))));
        float4 avgSet = float4(cmaaUnpackH(p1), cmaaUnpackV(p1),
                               cmaaUnpackV(p0_right), cmaaUnpackH(p0_below));
        float thr = cmaaLocalThreshold(avgSet, maxN);
        int flags = cmaaKeepFlags(float2(cmaaUnpackH(p3), cmaaUnpackV(p3)), thr);
        cmaaStoreRefined(flags, base + int2(1, 1));
    }
}
