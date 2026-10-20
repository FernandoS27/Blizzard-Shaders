// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Shadow cookie casters whose tint is not the caster-wide Factor alone
// (Shadows.fx vs_write_cookie_vertalpha).
//
// The same projection as cookie_vs -- the caster through world-view-projection,
// its UV through matTex0, the projected position again as a projective screen
// coordinate, the user clip planes -- with the colour handed to the cookie
// pixel stage chosen by a tint policy.

implementing d3_shaders;

/// The colour a cookie caster hands to the pixel stage.
public interface ICookieTint
{
    static float4 tint(D3VertexIn i);
}

/// The caster-wide intensity `Factor.w` in every channel.
public struct TintFactor : ICookieTint
{
    public static float4 tint(D3VertexIn i) { return Factor.wwww; }
};

/// The caster-wide intensity faded by the vertex colour's alpha.
public struct TintVertexAlpha : ICookieTint
{
    public static float4 tint(D3VertexIn i) { return i.color0().wwww * Factor.wwww; }
};

[shader("vertex")]
public D3Interpolants cookie_tint_vs_main<TSkin : ISkin, TTint : ICookieTint>(D3VertexIn i)
{
    D3Interpolants o = D3Interpolants.zero();
    D3ObjectVertex v = TSkin.apply(i);
    float4 clipPos = mul(matWorldViewProj, v.position);
    o.setPosition(clipPos);
    o.setTexcoord0(d3TextureMatrixTransform(0, d3DecodeUv0(i.texcoord0Bits())));
    o.setTexcoord1(float4((clipPos.xy + clipPos.w) * 0.5, clipPos.zw));
    o.setColor0(TTint.tint(i));
    d3WriteClipPlanes(clipPos, o);
    return o;
}
