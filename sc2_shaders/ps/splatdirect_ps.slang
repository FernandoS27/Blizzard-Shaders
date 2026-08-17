// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// SplatDirect pixel shader entry (splatdirect.fx : SplatDirectPixelMain).
//
// The legacy splat PS is a thin wrapper over the shared DefaultPixelMain: with the
// (compile-time) b_stencilFillPass axis set it writes a constant stencil-fill
// value into the colour + MRT targets, otherwise it tail-calls DefaultPixelMain.
// The permutation key is the Model family schema (sc2_model_key_decode.decode_ps —
// SplatDirect links the identical shared sub-sections, its header ceils to the same
// byte as Model's) plus this single own-family axis b_stencilFillPass at physical
// bit 104 (PermSchema_FinalizeLayout: the direct family axis at FinalizeLayout-88).

implementing sc2_shaders;

#ifndef b_stencilFillPass
#define b_stencilFillPass 0
#endif
#ifndef b_emitMRTDepth
#define b_emitMRTDepth 0
#endif
#ifndef b_emitMRTNormal
#define b_emitMRTNormal 0
#endif
#ifndef b_emitMRTDiffuse
#define b_emitMRTDiffuse 0
#endif
#ifndef b_emitMRTSpecular
#define b_emitMRTSpecular 0
#endif

[shader("fragment")]
public ModelPSOutput splatdirect_ps_main(ModelPSInput vertOut)
{
#if b_stencilFillPass
    // Stencil-fill branch (splatdirect.fx:238-263): constant white + MRT markers.
    ModelPSOutput outValue;
    outValue.cColor = 1;
    #if (b_emitMRTDepth == 1 || b_emitMRTNormal == 1)
    outValue.vNormalDepth = 0;
    #endif
    #if (b_emitMRTDepth == 1)
    outValue.vNormalDepth = 1;
    #endif
    #if (b_emitMRTNormal == 1)
    outValue.vNormalDepth = 1;
        #if (b_emitMRTDepth == 0)
    outValue.vNormalDepth.a = outValue.cColor.a;
        #endif
    #endif
    #if (b_emitMRTDiffuse == 1)
    outValue.cDiffuse = 1;
    #endif
    #if (b_emitMRTSpecular == 1)
    outValue.cSpecular = 1;
    #endif
    return outValue;
#else
    return computeModelPixel(vertOut);
#endif
}
