// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// The shader-side alpha test against `alphaTestRef.w`.
//
// Retail spells the test four ways, and they are four different programs: they
// agree on every ordinary alpha and disagree when alpha equals the reference
// exactly (and when alpha is NaN). One residue program (plan M7) has a fifth,
// keeping only the fragments whose alpha EQUALS the reference. The spelling is
// measured from each retail program (d3_perms `alphaCompare`) and the D4 tie
// trials check it. Every retail test is the compare instruction shown followed
// by `ieq 0` and `discard_nz`: it KEEPS the fragment when the compare holds, so
// a NaN alpha (every compare false) is discarded by all five.
//
//   DiscardLE   keep if ref <  a        lt ref, a
//   DiscardLT   keep if a   >= ref      ge a, ref
//   DiscardGE   keep if a   <  ref      lt a, ref
//   DiscardGT   keep if ref >= a        ge ref, a
//   DiscardNE   keep if a   == ref      eq a, ref
//
// The negation is spelled `(compare) == false`: d3dcompiler_47 folds `!(x < y)`
// into `ge x, y`, which keeps a NaN, while `== false` stays `lt x, y` +
// `discard_z` -- the retail test.

implementing d3_shaders;

public interface IAlphaTest
{
    static void apply(float alpha);
}

public struct AlphaTestOff : IAlphaTest
{
    public static void apply(float alpha) {}
};

public struct DiscardLE : IAlphaTest
{
    public static void apply(float alpha) { if ((alphaTestRef.w < alpha) == false) discard; }
};

public struct DiscardLT : IAlphaTest
{
    public static void apply(float alpha) { if ((alpha >= alphaTestRef.w) == false) discard; }
};

public struct DiscardGE : IAlphaTest
{
    public static void apply(float alpha) { if ((alpha < alphaTestRef.w) == false) discard; }
};

public struct DiscardGT : IAlphaTest
{
    public static void apply(float alpha) { if ((alphaTestRef.w >= alpha) == false) discard; }
};

public struct DiscardNE : IAlphaTest
{
    public static void apply(float alpha) { if ((alpha == alphaTestRef.w) == false) discard; }
};
