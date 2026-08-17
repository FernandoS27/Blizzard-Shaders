// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// MinimapTerrain family (minimapterrain.fx) — VS + PS.
//
// Composites the minimap: terrain over water, then (when the map overlay is off)
// creep tint and fog of war on top.  `MinimapTerrain_BuildSection` @0x102b5e430
// registers exactly two own axes and links NO shared sub-sections at all, which is
// why its retail set is precisely the 2x2 of those booleans:
//
//     b_showMap             @104 w1   overlay mode — skips creep + FOW
//     b_iScaleAlphaToTerrain@105 w1   multiply the result alpha by the terrain's
//
// Its FOW is hand-rolled here rather than psfow.fx's ApplyFogOfWar, so it does not
// share the FOW axes; it declares its own vertex format, hence
// `inject_preamble: false`.

implementing sc2_shaders;

#ifndef b_showMap
#define b_showMap 0
#endif
#ifndef b_iScaleAlphaToTerrain
#define b_iScaleAlphaToTerrain 0
#endif

// minimapterrain.fx : SMinimapTerrainVtxFmtGeneric (VS in) / SMinimapTerrainVtxFmt.
public struct MinimapTerrainVSInput
{
    float4 vPos : POSITION;
    float4 vTC0 : TEXCOORD0;
    float4 vTC1 : TEXCOORD1;
    float4 vTC2 : TEXCOORD2;
    float4 vTC3 : TEXCOORD3;
};

public struct MinimapTerrainTransport
{
    float4 vPos : SV_Position;
    float4 vTC0 : TEXCOORD0;
    float4 vTC1 : TEXCOORD1;
    float4 vTC2 : TEXCOORD2;
    float4 vTC3 : TEXCOORD3;
};

[shader("vertex")]
public MinimapTerrainTransport minimapterrain_vs_main(MinimapTerrainVSInput IN)
{
    MinimapTerrainTransport OUT;
    OUT.vPos = mul(IN.vPos, vsGlobals.mTransform);
    OUT.vTC0 = IN.vTC0;
    OUT.vTC1 = IN.vTC1;
    OUT.vTC2 = IN.vTC2;
    OUT.vTC3 = IN.vTC3;
    return OUT;
}

[shader("pixel")]
public float4 minimapterrain_ps_main(MinimapTerrainTransport IN) : SV_Target0
{
    float4 terrainColor = p_sTerrainTexture_t.Sample(p_sSamp, IN.vTC0.xy);
    float4 waterColor = p_sWaterTexture_t.Sample(p_sSamp, IN.vTC3.xy);
    float4 color = lerp(terrainColor, waterColor, waterColor.w);

#if !b_showMap
    {
        float4 creepTex = p_sCreepTexture_t.Sample(p_sSamp, IN.vTC1.xy);
        color.rgb = lerp(color.rgb, float3(0.375f, 0.114f, 0.550f), creepTex.w * 0.5f);

        float4 cFOWFactor;
        cFOWFactor.rgb = saturate(2.f * p_sFowTexture_t.Sample(p_sSamp, IN.vTC2.xy).rgb);
        cFOWFactor.a = dot(cFOWFactor.rgb, psGlobals.vFOWLevels.rgb);
        cFOWFactor.rgb = float3(0.f, 0.f, 0.f);

        // Only fully opaque pixels get fog of war applied.
        color.rgb = lerp(color.rgb, cFOWFactor.rgb,
                         terrainColor.a < 1.0f ? 0 : cFOWFactor.a);
    }
#endif

#if b_iScaleAlphaToTerrain
    color.a *= terrainColor.a;
#endif

    return color * psGlobals.vColor;
}
