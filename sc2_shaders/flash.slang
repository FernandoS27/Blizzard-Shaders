// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Flash family (flash.fx) — VS + PS.
//
// The Scaleform/Flash UI backend: a fixed vertex format plus two pure dispatch
// axes, one per stage.  `Flash_BuildSection` @0x102b490a0 registers exactly two
// own axes and links NO shared sub-sections:
//
//     b_iVertexShader @104 w3  (cardinality 5  -> 5 vertex layouts)
//     b_iPixelShader  @107 w4  (cardinality 14 -> 14 colour-transform modes)
//
// The retail set matches that exactly: 5 VS permutations (b_iVertexShader 0..4,
// b_iPixelShader pinned 0) and 14 PS permutations (b_iPixelShader 0..13).
//
// Own vertex format (SFlashVtxFmt), so `inject_preamble: false`.

implementing sc2_shaders;

#ifndef b_iVertexShader
#define b_iVertexShader 0
#endif
#ifndef b_iPixelShader
#define b_iPixelShader 0
#endif

// flash.fx vertex-shader types (must match the interface code).
#define e_flashVertexShaderStrip        0
#define e_flashVertexShaderGlyph        1
#define e_flashVertexShaderXY16iC32     2
#define e_flashVertexShaderXY16iCF32    3
#define e_flashVertexShaderXY16iCF32_T2 4

// flash.fx pixel-shader types.
#define e_flashPixelShaderSolidColor                      0
#define e_flashPixelShaderCxformTexture                   1
#define e_flashPixelShaderCxformTextureMultiply           2
#define e_flashPixelShaderTextTextureAlpha                3
#define e_flashPixelShaderTextTextureColor                4
#define e_flashPixelShaderTextTextureColorMultiply        5
#define e_flashPixelShaderCxformGauraud                   6
#define e_flashPixelShaderCxformGauraudNoAddAlpha         7
#define e_flashPixelShaderCxformGauraudTexture            8
#define e_flashPixelShaderCxform2Texture                  9
#define e_flashPixelShaderCxformGauraudMultiply           10
#define e_flashPixelShaderCxformGauraudMultiplyNoAddAlpha 11
#define e_flashPixelShaderCxformGauraudMultiplyTexture    12
#define e_flashPixelShaderCxformMultiply2Texture          13

public struct FlashVSInput
{
    float4 vPos      : POSITION;
    float4 cColor0   : COLOR0;
    float4 cFactor0  : COLOR1;
    float2 vTC0      : TEXCOORD0;
    float2 vTC1      : TEXCOORD1;
};

// flash.fx : SFlashVtxFmt.
public struct FlashTransport
{
    float4 vPos     : SV_Position;
    float4 cColor0  : COLOR0;
    float4 cFactor0 : COLOR1;
    float2 vTC0     : TEXCOORD0;
    float2 vTC1     : TEXCOORD1;
};

public struct FlashPSInput
{
    float4 vPos     : SV_Position;
    float4 cColor0  : COLOR0;
    float4 cFactor0 : COLOR1;
    float2 vTC0     : TEXCOORD0;
    float2 vTC1     : TEXCOORD1;
};

[shader("vertex")]
public FlashTransport flash_vs_main(FlashVSInput IN)
{
    FlashTransport OUT;
    // Each arm writes only the fields its vertex layout carries; the rest are
    // left at the struct's initial value (the original simply does not assign
    // them, which fxc lowers to an unwritten output register).
    OUT.vPos = float4(0, 0, 0, 0);
    OUT.cColor0 = float4(0, 0, 0, 0);
    OUT.cFactor0 = float4(0, 0, 0, 0);
    OUT.vTC0 = float2(0, 0);
    OUT.vTC1 = float2(0, 0);

    // NOTE: matrix * VECTOR here (the original writes `mul(p_mTransform, IN.vPos)`),
    // not the vector * matrix form the model roots use.
#if (b_iVertexShader == e_flashVertexShaderStrip)
    OUT.vPos = mul(vsGlobals.mTransform, IN.vPos);
    OUT.vTC0.x = dot(IN.vPos, vsGlobals.mTexgen0);
    OUT.vTC0.y = dot(IN.vPos, vsGlobals.mTexgen1);
    OUT.cColor0 = IN.cColor0;
    OUT.cFactor0 = IN.cFactor0;
#elif (b_iVertexShader == e_flashVertexShaderGlyph)
    OUT.vPos = mul(vsGlobals.mTransform, IN.vPos);
    OUT.vTC0 = IN.vTC0;
    OUT.vTC1 = IN.vTC1;
    OUT.cColor0 = IN.cColor0;
    OUT.cFactor0 = IN.cFactor0;
#elif (b_iVertexShader == e_flashVertexShaderXY16iC32)
    OUT.vPos = mul(vsGlobals.mTransform, IN.vPos);
    OUT.vTC0.x = dot(IN.vPos, vsGlobals.mTexgen0);
    OUT.vTC0.y = dot(IN.vPos, vsGlobals.mTexgen1);
    OUT.vTC1 = IN.vTC1;
    OUT.cColor0 = IN.cColor0;
    OUT.cFactor0 = IN.cFactor0;
#elif (b_iVertexShader == e_flashVertexShaderXY16iCF32)
    OUT.vPos = mul(vsGlobals.mTransform, IN.vPos);
    OUT.vTC0.x = dot(IN.vPos, vsGlobals.mTexgen0);
    OUT.vTC0.y = dot(IN.vPos, vsGlobals.mTexgen1);
    OUT.vTC1 = IN.vTC1;
    OUT.cColor0 = IN.cColor0;
    OUT.cFactor0 = IN.cFactor0;
#elif (b_iVertexShader == e_flashVertexShaderXY16iCF32_T2)
    OUT.vPos = mul(vsGlobals.mTransform, IN.vPos);
    OUT.vTC0.x = dot(IN.vPos, vsGlobals.mTexgen0);
    OUT.vTC0.y = dot(IN.vPos, vsGlobals.mTexgen1);
    OUT.vTC1.x = dot(IN.vPos, vsGlobals.mTexgen2);
    OUT.vTC1.y = dot(IN.vPos, vsGlobals.mTexgen3);
    OUT.cColor0 = IN.cColor0;
    OUT.cFactor0 = IN.cFactor0;
#endif

    return OUT;
}

[shader("pixel")]
public float4 flash_ps_main(FlashPSInput IN) : SV_Target0
{
    float4 outColor = float4(0, 0, 0, 0);

#if (b_iPixelShader == e_flashPixelShaderSolidColor)
    outColor = psGlobals.vColor;
#elif (b_iPixelShader == e_flashPixelShaderCxformTexture)
    outColor = p_sTexture0_t.Sample(p_sSamp, IN.vTC0.xy) * psGlobals.vColorTransformMul
             + psGlobals.vColorTransformAdd;
#elif (b_iPixelShader == e_flashPixelShaderCxformTextureMultiply)
    {
        float4 color = p_sTexture0_t.Sample(p_sSamp, IN.vTC0.xy);
        color = color * psGlobals.vColorTransformMul + psGlobals.vColorTransformAdd;
        outColor = lerp(float4(1, 1, 1, 1), color, color.a);
    }
#elif (b_iPixelShader == e_flashPixelShaderTextTextureAlpha)
    {
        float4 color = IN.cColor0 * psGlobals.vColorTransformMul + psGlobals.vColorTransformAdd;
        color.a = color.a * p_sTexture0_t.Sample(p_sSamp, IN.vTC0.xy).a;
        outColor = color;
    }
#elif (b_iPixelShader == e_flashPixelShaderTextTextureColor)
    {
        float4 color = p_sTexture0_t.Sample(p_sSamp, IN.vTC0.xy);
        color = color * psGlobals.vColorTransformMul + psGlobals.vColorTransformAdd;
        outColor = color;
    }
#elif (b_iPixelShader == e_flashPixelShaderTextTextureColorMultiply)
    {
        float4 color = p_sTexture0_t.Sample(p_sSamp, IN.vTC0.xy);
        color = color * psGlobals.vColorTransformMul + psGlobals.vColorTransformAdd;
        outColor = lerp(float4(1, 1, 1, 1), color, color.a);
    }
#elif (b_iPixelShader == e_flashPixelShaderCxformGauraud)
    {
        float4 color = IN.cColor0;
        color = color * psGlobals.vColorTransformMul + psGlobals.vColorTransformAdd;
        color.a = color.a * IN.cFactor0.a;
        outColor = color;
    }
#elif (b_iPixelShader == e_flashPixelShaderCxformGauraudNoAddAlpha)
    outColor = IN.cColor0 * psGlobals.vColorTransformMul + psGlobals.vColorTransformAdd;
#elif (b_iPixelShader == e_flashPixelShaderCxformGauraudTexture)
    {
        float4 color = lerp(IN.cColor0, p_sTexture0_t.Sample(p_sSamp, IN.vTC0.xy),
                            IN.cFactor0.b);
        color = color * psGlobals.vColorTransformMul + psGlobals.vColorTransformAdd;
        color.a = color.a * IN.cFactor0.a;
        outColor = color;
    }
#elif (b_iPixelShader == e_flashPixelShaderCxform2Texture)
    {
        float4 color = lerp(p_sTexture1_t.Sample(p_sSamp, IN.vTC1.xy),
                            p_sTexture0_t.Sample(p_sSamp, IN.vTC0.xy), IN.cFactor0.b);
        outColor = color * psGlobals.vColorTransformMul + psGlobals.vColorTransformAdd;
    }
#elif (b_iPixelShader == e_flashPixelShaderCxformGauraudMultiply)
    {
        float4 color = IN.cColor0 * psGlobals.vColorTransformMul + psGlobals.vColorTransformAdd;
        color.a = color.a * IN.cFactor0.a;
        outColor = lerp(float4(1, 1, 1, 1), color, color.a);
    }
#elif (b_iPixelShader == e_flashPixelShaderCxformGauraudMultiplyNoAddAlpha)
    {
        float4 color = IN.cColor0 * psGlobals.vColorTransformMul + psGlobals.vColorTransformAdd;
        outColor = lerp(float4(1, 1, 1, 1), color, color.a);
    }
#elif (b_iPixelShader == e_flashPixelShaderCxformGauraudMultiplyTexture)
    {
        float4 color = lerp(IN.cColor0, p_sTexture0_t.Sample(p_sSamp, IN.vTC0.xy),
                            IN.cFactor0.b);
        color = color * psGlobals.vColorTransformMul + psGlobals.vColorTransformAdd;
        color.a = color.a * IN.cFactor0.a;
        outColor = lerp(float4(1, 1, 1, 1), color, color.a);
    }
#elif (b_iPixelShader == e_flashPixelShaderCxformMultiply2Texture)
    {
        float4 color = lerp(p_sTexture1_t.Sample(p_sSamp, IN.vTC1.xy),
                            p_sTexture0_t.Sample(p_sSamp, IN.vTC0.xy), IN.cFactor0.b);
        color = color * psGlobals.vColorTransformMul + psGlobals.vColorTransformAdd;
        outColor = lerp(float4(1, 1, 1, 1), color, color.a);
    }
#endif

    outColor.a = outColor.a * psGlobals.fFrameAlpha;

    return outColor;
}
