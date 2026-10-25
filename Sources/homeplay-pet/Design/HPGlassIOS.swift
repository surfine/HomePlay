// 2.0 glass（第二次校準）：iOS 家族的 Liquid Glass——HomeView 跑的是 iOS 系的玻璃，不是 macOS 的 NSGlassEffectView。
//
// 量法（2026-10-25）：iOS 27 模擬器（Clio iPhone A，iPhone 17 Pro）跑一個 SwiftUI 小 App，`.glassEffect(.regular／.clear)`，
// 拆 UIKit 的層樹：結構跟 macOS 一模一樣（CABackdropLayer glassBackground → CASDFLayer @0／@2），只有參數不同——
// - Clear 幾乎不模糊（inputBlurRadius 0.75 pt，macOS 7.8）、面色不加白（fill 0）、white 1.08：更透明；
// - Regular 的模糊只在外圈（inputBlurDistance0 = −短邊／2、BlurOpacity 0.2–0.8 跟尺寸走），中心幾乎是清的；
// - 外折射（inputOuterRefraction*）與濾鏡自己畫的外陰影（inputShadowOpacity／Radius，CASDFOutputEffect maximum 9–40 pt）；
// - @2 亮邊靜止就開著（opacity 1、keyColor／fillColor alpha 1），經過 vibrantColorMatrix——亮緣吃到背景的顏色；
// - 染色：vibrantColorMatrix 是「背景亮度 → 在暗端與染色之間內插」（每列＝亮度權重 × (亮端 − 暗端)，位移＝暗端）。
// 尺寸規律從 16–400 pt 的掃描表來（短邊每 8 pt 一筆，取折點）；數字由 scratchpad/iosglass/gen.py、tintgen.py 產生。
// NativeGlass 照舊建 macOS 的層樹，platform = .iOS 時用這裡把參數換成 iOS 的（IOSGlass.apply）。

import AppKit
import QuartzCore

/// 玻璃長哪一家的樣子：HomeView 畫面用 iOS（預設）；校準台與 Mac 原生介面用 macOS
enum HPGlassPlatform: String {
    case macOS, iOS
}

enum IOSGlass {
    struct Look {
        /// glassBackground 的固定值
        let constants: [String: Double]
        /// 顏色參數（sRGB RGBA）
        let colors: [String: [Double]]
        /// 跟短邊（pt）走的值：折線 (短邊, 值)，超出範圍沿最後一段外插
        let curves: [String: [(Double, Double)]]
        /// @2 亮邊效果（CASDFKeyFillHighlightEffect）的固定值
        let highlight: [String: Double]
    }
    /// 染色：暗端（背景亮度 0）與亮端（亮度 1）各是染色 sRGB 的仿射函數，再加量測樣本的殘差（距離加權，樣本上剛好吻合）
    struct TintLaw {
        let lowAffine: [Double], highAffine: [Double], samples: [Double], lowResidual: [Double], highResidual: [Double]
        let neutralDiag: Double, neutralBlack: Double, neutralWhite: Double
    }

    static let regularLight = Look(
        constants: ["inputBleedColorMatrixBlack": 0.9, "inputBleedColorMatrixSaturation": 1.2, "inputBleedColorMatrixWhite": 1, "inputBleedDarkenBlend": 1, "inputBleedDistance0": 1, "inputBleedDistance1": 0, "inputBlurDistance1": -1, "inputBlurDistance2": 0, "inputBlurDistance3": 0, "inputBlurFillBlurRadius": 8, "inputBlurFillDarkenOpacity": 0, "inputBlurFillLightenOpacity": 0.9, "inputBlurFillNormalOpacity": 0.5, "inputBlurOpacity2": 0.5, "inputBlurOpacity3": 1, "inputBlurRadius": 5, "inputClamp": 1.06961, "inputClampPreserveHue": 0, "inputFaceColorMatrixBlack": 0.4, "inputFaceColorMatrixMaxLuma": 1, "inputFaceColorMatrixMaxLumaSDR": 0.94, "inputFaceColorMatrixSaturation": 1.2, "inputFaceColorMatrixWhite": 1.03, "inputFaceOpacity": 1, "inputKeyFillHighlightAmount": 0.4, "inputKeyFillHighlightAngle": 1.5708, "inputKeyFillHighlightColorBias": -0.3, "inputKeyFillHighlightEffectOffset": -0.533333, "inputKeyFillHighlightHeight": 0.533333, "inputKeyFillHighlightSpread": 1.67552, "inputKeyFillHighlightSpreadSDR": 1.85005, "inputMaxHeadroom": 9999, "inputRefractionDistance0": -1, "inputRefractionDistance1": 0, "inputRefractionOpacity": 0.6, "inputRingShadowBlurRadius": 5, "inputRingShadowMask": 1, "inputRingShadowOffset": 8, "inputRingShadowOpacity": 0.06, "inputRingShadowStrokeWidth": 4, "inputSDRGradientDistance0": 0, "inputSDRGradientDistance1": 0, "inputSDRHoldingToneEnabled": 0, "inputSDRHoldingToneWhite": 1, "inputSDRShadowOpacity": 0, "inputShadowAmount": 0, "inputShadowBlurRadius": 0, "inputShadowColorMatrixBlack": 0, "inputShadowColorMatrixSaturation": 1, "inputShadowColorMatrixWhite": 1, "inputShadowDistanceOffset": 0, "inputShadowHeight": 0, "inputShadowVibrancyContribution": 0],
        colors: ["inputFaceColorMatrixFillColor": [1, 1, 1, 0.2], "inputShadowColorMatrixFillColor": [0, 0, 0, 0.3]],
        curves: ["fillSpread": [(16, 1.39626), (96, 1.39626), (192, 1.5708), (400, 1.5708)], "inputBleedAmount": [(16, 5.6), (400, 140)], "inputBleedBlurRadius": [(16, 0), (64, 0), (72, 25.2), (400, 140)], "inputBleedHeight": [(16, 5.6), (400, 140)], "inputBleedOpacity": [(16, 0), (64, 0), (160, 0.5), (400, 0.5)], "inputBlurDistance0": [(16, -8), (400, -200)], "inputBlurOpacity0": [(16, 0), (64, 0), (160, 0.8), (400, 0.8)], "inputBlurOpacity1": [(16, 0), (64, 0), (160, 0.4), (400, 0.4)], "inputInnerRefractionAmount": [(16, -8), (120, -60), (400, -60)], "inputInnerRefractionHeight": [(16, 4), (80, 20), (400, 20)], "inputOuterRefractionAmount": [(16, 16), (64, 16), (400, 100)], "inputOuterRefractionHeight": [(16, 16), (80, 16), (400, 80)], "inputShadowOpacity": [(16, 0.04), (64, 0.04), (160, 0.4), (400, 0.4)], "inputShadowRadius": [(16, 4), (64, 4), (160, 24), (400, 24)], "keySpread": [(16, 1.39626), (96, 1.39626), (192, 1.5708), (400, 1.5708)], "marginWidth": [(16, 16), (64, 16), (72, 25.2), (400, 140)], "outputMaximum": [(16, 8.89036), (80, 8.89036), (88, 11.107), (96, 13.8522), (104, 16.6713), (112, 19.5553), (120, 22.4973), (128, 25.4912), (136, 28.5325), (144, 31.617), (152, 34.7414), (160, 37.9028), (400, 37.9028)]],
        highlight: ["curvature": 0.75, "diffuseAmountScale": 0.15, "diffuseHeightScale": 8, "diffuseSpreadScale": 0.65, "fillAmount": 0.5, "fillAngle": 3.14159, "fillHeight": 1, "fillHeightOffset": 0, "fillHeightScale": 1, "fillSpreadOffset": 0, "fillSpreadScale": 1, "global": 0, "keyAmount": 0.5, "keyAngle": 0, "keyHeight": 1, "keyHeightOffset": 0, "keyHeightScale": 1, "keySpreadOffset": 0, "keySpreadScale": 1])
    static let regularDark = Look(
        constants: ["inputBleedColorMatrixBlack": 0.125, "inputBleedColorMatrixSaturation": 1, "inputBleedColorMatrixWhite": 0.5, "inputBleedDarkenBlend": 0, "inputBleedDistance0": 1, "inputBleedDistance1": 0, "inputBlurDistance1": -1, "inputBlurDistance2": 0, "inputBlurDistance3": 0, "inputBlurFillBlurRadius": 8, "inputBlurFillDarkenOpacity": 0.9, "inputBlurFillLightenOpacity": 0, "inputBlurFillNormalOpacity": 0.5, "inputBlurOpacity2": 0.5, "inputBlurOpacity3": 1, "inputBlurRadius": 5, "inputClamp": 1.30831, "inputClampPreserveHue": 0, "inputFaceColorMatrixBlack": 0.125, "inputFaceColorMatrixSaturation": 1.3, "inputFaceColorMatrixWhite": 1.125, "inputFaceOpacity": 1, "inputKeyFillHighlightAmount": 0.4, "inputKeyFillHighlightAngle": 1.5708, "inputKeyFillHighlightColorBias": -0.3, "inputKeyFillHighlightEffectOffset": -0.533333, "inputKeyFillHighlightHeight": 0.533333, "inputKeyFillHighlightSpread": 1.309, "inputKeyFillHighlightSpreadSDR": 1.309, "inputMaxHeadroom": 9999, "inputRefractionDistance0": -1, "inputRefractionDistance1": 0, "inputRefractionOpacity": 0.6, "inputRingShadowBlurRadius": 5, "inputRingShadowMask": 1, "inputRingShadowOffset": 8, "inputRingShadowOpacity": 0.06, "inputRingShadowStrokeWidth": 4, "inputSDRGradientDistance0": 0, "inputSDRGradientDistance1": 0, "inputSDRHoldingToneEnabled": 0, "inputSDRHoldingToneWhite": 1, "inputSDRShadowOpacity": 0, "inputShadowAmount": 0, "inputShadowBlurRadius": 0, "inputShadowColorMatrixBlack": 0, "inputShadowColorMatrixSaturation": 1, "inputShadowColorMatrixWhite": 1, "inputShadowDistanceOffset": 0, "inputShadowHeight": 0, "inputShadowVibrancyContribution": 0],
        colors: ["inputFaceColorMatrixFillColor": [0, 0, 0, 0], "inputShadowColorMatrixFillColor": [0, 0, 0, 0.3]],
        curves: ["fillSpread": [(16, 1.39626), (96, 1.39626), (192, 1.5708), (400, 1.5708)], "inputBleedAmount": [(16, 5.6), (400, 140)], "inputBleedBlurRadius": [(16, 0), (64, 0), (72, 25.2), (400, 140)], "inputBleedHeight": [(16, 5.6), (400, 140)], "inputBleedOpacity": [(16, 0), (64, 0), (160, 0.8), (400, 0.8)], "inputBlurDistance0": [(16, -8), (400, -200)], "inputBlurOpacity0": [(16, 0), (64, 0), (160, 0.8), (400, 0.8)], "inputBlurOpacity1": [(16, 0), (64, 0), (160, 0.4), (400, 0.4)], "inputFaceColorMatrixMaxLuma": [(16, 0.6), (64, 0.6), (104, 0.35), (400, 0.35)], "inputFaceColorMatrixMaxLumaSDR": [(16, 0.6), (64, 0.6), (104, 0.35), (400, 0.35)], "inputInnerRefractionAmount": [(16, -8), (120, -60), (400, -60)], "inputInnerRefractionHeight": [(16, 4), (80, 20), (400, 20)], "inputOuterRefractionAmount": [(16, 16), (64, 16), (400, 100)], "inputOuterRefractionHeight": [(16, 16), (80, 16), (400, 80)], "inputShadowOpacity": [(16, 0.04), (64, 0.04), (160, 0.6), (400, 0.6)], "inputShadowRadius": [(16, 4), (64, 4), (160, 24), (400, 24)], "keySpread": [(16, 1.39626), (96, 1.39626), (192, 1.5708), (400, 1.5708)], "marginWidth": [(16, 16), (64, 16), (72, 25.2), (400, 140)], "outputMaximum": [(16, 8.89036), (72, 8.89036), (80, 9.10805), (88, 12.0155), (96, 14.997), (104, 18.0472), (112, 21.1595), (120, 24.3277), (128, 27.5469), (136, 30.8124), (144, 34.1035), (152, 36.959), (160, 39.8303), (400, 39.8303)]],
        highlight: ["curvature": 0.75, "diffuseAmountScale": 0.15, "diffuseHeightScale": 8, "diffuseSpreadScale": 0.65, "fillAmount": 0.5, "fillAngle": 3.14159, "fillHeight": 1, "fillHeightOffset": 0, "fillHeightScale": 1, "fillSpreadOffset": 0, "fillSpreadScale": 1, "global": 0, "keyAmount": 0.5, "keyAngle": 0, "keyHeight": 1, "keyHeightOffset": 0, "keyHeightScale": 1, "keySpreadOffset": 0, "keySpreadScale": 1])
    static let clearLight = Look(
        constants: ["inputBleedAmount": 0, "inputBleedBlurRadius": 0, "inputBleedColorMatrixBlack": 0.75, "inputBleedColorMatrixSaturation": 1.2, "inputBleedColorMatrixWhite": 1, "inputBleedDarkenBlend": 1, "inputBleedDistance0": 1, "inputBleedDistance1": 0, "inputBleedHeight": 0, "inputBleedOpacity": 0, "inputBlurDistance1": -1, "inputBlurDistance2": 0, "inputBlurDistance3": 0, "inputBlurFillBlurRadius": 0, "inputBlurFillDarkenOpacity": 0, "inputBlurFillLightenOpacity": 0, "inputBlurFillNormalOpacity": 0, "inputBlurOpacity0": 1, "inputBlurOpacity1": 0.5, "inputBlurOpacity2": 0.5, "inputBlurOpacity3": 1, "inputBlurRadius": 0.75, "inputClamp": 1.19175, "inputClampPreserveHue": 0, "inputFaceColorMatrixBlack": 0.125, "inputFaceColorMatrixMaxLuma": 1, "inputFaceColorMatrixMaxLumaSDR": 1, "inputFaceColorMatrixSaturation": 1.06, "inputFaceColorMatrixWhite": 1.08, "inputFaceOpacity": 1, "inputKeyFillHighlightAmount": 0.4, "inputKeyFillHighlightAngle": 1.5708, "inputKeyFillHighlightColorBias": -0.3, "inputKeyFillHighlightEffectOffset": -0.533333, "inputKeyFillHighlightHeight": 0.533333, "inputKeyFillHighlightSpread": 1.309, "inputKeyFillHighlightSpreadSDR": 1.309, "inputMaxHeadroom": 9999, "inputRefractionDistance0": -1, "inputRefractionDistance1": 0, "inputRefractionOpacity": 0, "inputRingShadowBlurRadius": 0, "inputRingShadowMask": 0, "inputRingShadowOffset": 0, "inputRingShadowOpacity": 0, "inputRingShadowStrokeWidth": 0, "inputSDRGradientDistance0": 0, "inputSDRGradientDistance1": 0, "inputSDRHoldingToneEnabled": 0, "inputSDRHoldingToneWhite": 1, "inputSDRShadowOpacity": 0, "inputShadowBlurRadius": 0, "inputShadowColorMatrixBlack": 0, "inputShadowColorMatrixSaturation": 1.2, "inputShadowColorMatrixWhite": 1, "inputShadowDistanceOffset": 0, "inputShadowOpacity": 0, "inputShadowRadius": 0, "inputShadowVibrancyContribution": 0],
        colors: ["inputFaceColorMatrixFillColor": [1, 1, 1, 0], "inputShadowColorMatrixFillColor": [0, 0, 0, 0.1]],
        curves: ["fillSpread": [(16, 1.39626), (96, 1.39626), (192, 1.5708), (400, 1.5708)], "inputBlurDistance0": [(16, -8), (400, -200)], "inputInnerRefractionAmount": [(16, -10.4), (88, -57.2), (96, -60), (400, -60)], "inputInnerRefractionHeight": [(16, 5.76), (48, 17.28), (56, 20), (400, 20)], "inputOuterRefractionAmount": [(16, 3.2), (400, 80)], "inputOuterRefractionHeight": [(16, 2), (400, 50)], "inputShadowAmount": [(16, 10), (120, 75), (400, 75)], "inputShadowHeight": [(16, 6.4), (400, 160)], "keySpread": [(16, 1.39626), (96, 1.39626), (192, 1.5708), (400, 1.5708)], "marginWidth": [(16, 0.533333), (400, 0.533333)], "outputMaximum": [(16, 1.53333), (400, 1.53333)]],
        highlight: ["curvature": 0.75, "diffuseAmountScale": 0.15, "diffuseHeightScale": 8, "diffuseSpreadScale": 0.65, "fillAmount": 0.5, "fillAngle": 3.14159, "fillHeight": 1, "fillHeightOffset": 0, "fillHeightScale": 1, "fillSpreadOffset": 0, "fillSpreadScale": 1, "global": 0, "keyAmount": 0.5, "keyAngle": 0, "keyHeight": 1, "keyHeightOffset": 0, "keyHeightScale": 1, "keySpreadOffset": 0, "keySpreadScale": 1])
    static let clearDark = Look(
        constants: ["inputBleedAmount": 0, "inputBleedBlurRadius": 0, "inputBleedColorMatrixBlack": 0.75, "inputBleedColorMatrixSaturation": 1.2, "inputBleedColorMatrixWhite": 1, "inputBleedDarkenBlend": 1, "inputBleedDistance0": 1, "inputBleedDistance1": 0, "inputBleedHeight": 0, "inputBleedOpacity": 0, "inputBlurDistance1": -1, "inputBlurDistance2": 0, "inputBlurDistance3": 0, "inputBlurFillBlurRadius": 0, "inputBlurFillDarkenOpacity": 0, "inputBlurFillLightenOpacity": 0, "inputBlurFillNormalOpacity": 0, "inputBlurOpacity0": 1, "inputBlurOpacity1": 0.5, "inputBlurOpacity2": 0.5, "inputBlurOpacity3": 1, "inputBlurRadius": 0.75, "inputClamp": 1.19175, "inputClampPreserveHue": 0, "inputFaceColorMatrixBlack": 0.125, "inputFaceColorMatrixMaxLuma": 1, "inputFaceColorMatrixMaxLumaSDR": 1, "inputFaceColorMatrixSaturation": 1.06, "inputFaceColorMatrixWhite": 1.08, "inputFaceOpacity": 1, "inputKeyFillHighlightAmount": 0.4, "inputKeyFillHighlightAngle": 1.5708, "inputKeyFillHighlightColorBias": -0.3, "inputKeyFillHighlightEffectOffset": -0.533333, "inputKeyFillHighlightHeight": 0.533333, "inputKeyFillHighlightSpread": 1.309, "inputKeyFillHighlightSpreadSDR": 1.309, "inputMaxHeadroom": 9999, "inputRefractionDistance0": -1, "inputRefractionDistance1": 0, "inputRefractionOpacity": 0, "inputRingShadowBlurRadius": 0, "inputRingShadowMask": 0, "inputRingShadowOffset": 0, "inputRingShadowOpacity": 0, "inputRingShadowStrokeWidth": 0, "inputSDRGradientDistance0": 0, "inputSDRGradientDistance1": 0, "inputSDRHoldingToneEnabled": 0, "inputSDRHoldingToneWhite": 1, "inputSDRShadowOpacity": 0, "inputShadowBlurRadius": 0, "inputShadowColorMatrixBlack": 0, "inputShadowColorMatrixSaturation": 1.2, "inputShadowColorMatrixWhite": 1, "inputShadowDistanceOffset": 0, "inputShadowOpacity": 0, "inputShadowRadius": 0, "inputShadowVibrancyContribution": 0],
        colors: ["inputFaceColorMatrixFillColor": [1, 1, 1, 0], "inputShadowColorMatrixFillColor": [0, 0, 0, 0.1]],
        curves: ["fillSpread": [(16, 1.39626), (96, 1.39626), (192, 1.5708), (400, 1.5708)], "inputBlurDistance0": [(16, -8), (400, -200)], "inputInnerRefractionAmount": [(16, -10.4), (88, -57.2), (96, -60), (400, -60)], "inputInnerRefractionHeight": [(16, 5.76), (48, 17.28), (56, 20), (400, 20)], "inputOuterRefractionAmount": [(16, 3.2), (400, 80)], "inputOuterRefractionHeight": [(16, 2), (400, 50)], "inputShadowAmount": [(16, 10), (120, 75), (400, 75)], "inputShadowHeight": [(16, 6.4), (400, 160)], "keySpread": [(16, 1.39626), (96, 1.39626), (192, 1.5708), (400, 1.5708)], "marginWidth": [(16, 0.533333), (400, 0.533333)], "outputMaximum": [(16, 1.53333), (400, 1.53333)]],
        highlight: ["curvature": 0.75, "diffuseAmountScale": 0.15, "diffuseHeightScale": 8, "diffuseSpreadScale": 0.65, "fillAmount": 0.5, "fillAngle": 3.14159, "fillHeight": 1, "fillHeightOffset": 0, "fillHeightScale": 1, "fillSpreadOffset": 0, "fillSpreadScale": 1, "global": 0, "keyAmount": 0.5, "keyAngle": 0, "keyHeight": 1, "keyHeightOffset": 0, "keyHeightScale": 1, "keySpreadOffset": 0, "keySpreadScale": 1])

    static let tintLaws: [String: TintLaw] = [
        "regular-light": TintLaw(lowAffine: [0.54817, -0.34145, -0.14604, 0.28556, -0.052343, 0.87105, -0.024525, -0.17111, 0.22266, 0.34708, 0.9084, -0.47951], highAffine: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0], samples: [1, 0.23, 0.19, 1, 0.58, 0, 1, 0.8, 0, 0.2, 0.78, 0.35, 0, 0.48, 1, 0.69, 0.32, 0.87, 0.56, 0.56, 0.58], lowResidual: [0.020073, -0.01282, -0.029103, -0.035699, 0.036594, 0.055546, 0.039419, -0.0075076, -0.020811, -0.012814, -0.035378, 0.011849, 0.024373, 0.028822, 0.0045129, -0.011026, -0.028868, 0.033193, -0.024326, 0.019157, -0.055187], highResidual: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -3.9086e-10, 0, 0, 0], neutralDiag: 0.3125, neutralBlack: -0.25, neutralWhite: 0.9375),
        "regular-dark": TintLaw(lowAffine: [1.0268, -0.0025788, -0.010282, -0.019837, -0.0020024, 1.0508, -0.00059477, -0.04052, 0.00024147, 0.01833, 1.0407, -0.044676], highAffine: [0.8482, 0.014614, 0.058266, 0.11241, 0.011347, 0.71205, 0.0033706, 0.22961, -0.0013683, -0.10387, 0.76954, 0.25316], samples: [1, 0.23, 0.19, 1, 0.58, 0, 1, 0.8, 0, 0.2, 0.78, 0.35, 0, 0.48, 1, 0.69, 0.32, 0.87, 0.56, 0.56, 0.58], lowResidual: [-8.4878e-05, -0.0012256, -0.0015778, 0.0001704, 0.0034492, 0.0031776, 0.00073774, 0.00024495, -0.00085509, 0.0001387, -0.0030562, 0.00012747, 0.0007322, 0.0034981, 0.00083247, 0.00075172, -0.00175, 0.0014186, -0.0024459, -0.0011604, -0.0031232], highResidual: [0.0004809, 0.0069452, 0.0089409, -0.00096547, -0.019546, -0.018006, -0.0041806, -0.0013879, 0.0048456, -0.00078597, 0.017319, -0.00072239, -0.004149, -0.019822, -0.0047172, -0.0042597, 0.0099166, -0.0080385, 0.01386, 0.0065754, 0.017698], neutralDiag: 0.3125, neutralBlack: -0.25, neutralWhite: 0.9375),
        "clear-light": TintLaw(lowAffine: [0.54817, -0.34145, -0.14604, 0.28556, -0.052343, 0.87105, -0.024525, -0.17111, 0.22266, 0.34708, 0.9084, -0.47951], highAffine: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0], samples: [1, 0.23, 0.19, 1, 0.58, 0, 1, 0.8, 0, 0.2, 0.78, 0.35, 0, 0.48, 1, 0.69, 0.32, 0.87, 0.56, 0.56, 0.58], lowResidual: [0.020073, -0.01282, -0.029103, -0.035699, 0.036594, 0.055546, 0.039419, -0.0075076, -0.020811, -0.012814, -0.035378, 0.011849, 0.024373, 0.028822, 0.0045129, -0.011026, -0.028868, 0.033193, -0.024326, 0.019157, -0.055187], highResidual: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -3.9086e-10, 0, 0, 0], neutralDiag: 0.3125, neutralBlack: -0.25, neutralWhite: 0.9375),
        "clear-dark": TintLaw(lowAffine: [0.54817, -0.34145, -0.14604, 0.28556, -0.052343, 0.87105, -0.024525, -0.17111, 0.22266, 0.34708, 0.9084, -0.47951], highAffine: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0], samples: [1, 0.23, 0.19, 1, 0.58, 0, 1, 0.8, 0, 0.2, 0.78, 0.35, 0, 0.48, 1, 0.69, 0.32, 0.87, 0.56, 0.56, 0.58], lowResidual: [0.020073, -0.01282, -0.029103, -0.035699, 0.036594, 0.055546, 0.039419, -0.0075076, -0.020811, -0.012814, -0.035378, 0.011849, 0.024373, 0.028822, 0.0045129, -0.011026, -0.028868, 0.033193, -0.024326, 0.019157, -0.055187], highResidual: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -3.9086e-10, 0, 0, 0], neutralDiag: 0.3125, neutralBlack: -0.25, neutralWhite: 0.9375),
    ]

    static func look(clear: Bool, dark: Bool) -> Look {
        clear ? (dark ? clearDark : clearLight) : (dark ? regularDark : regularLight)
    }

    /// 折線取值（短邊 pt）；超出兩端沿端點那一段外插（例：bleed＝0.35 × 短邊一直成立）
    static func value(_ c: [(Double, Double)], _ s: Double) -> Double {
        guard let first = c.first, let last = c.last else { return 0 }
        if c.count == 1 { return first.1 }
        if s <= first.0 { return first.1 }
        if s >= last.0 {
            let a = c[c.count - 2]
            return last.0 == a.0 ? last.1 : last.1 + (last.1 - a.1) / (last.0 - a.0) * (s - last.0)
        }
        for i in 1..<c.count where s <= c[i].0 {
            let a = c[i - 1], b = c[i]
            return a.1 + (b.1 - a.1) * (s - a.0) / (b.0 - a.0)
        }
        return last.1
    }
    /// 內折射與模糊距離跟容器裡最小的形狀走，其餘跟最大的（iOS 容器實測：✕ 48 pt＋膠囊 68 pt）
    static func usesMinSide(_ key: String) -> Bool { key.hasPrefix("inputInnerRefraction") || key == "inputBlurDistance0" }

    /// 濾鏡自己畫的外陰影伸到形狀外多遠（pt）：貼回去時要把這一圈一起貼
    static func outputMaximum(side: Double, clear: Bool, dark: Bool) -> Double {
        look(clear: clear, dark: dark).curves["outputMaximum"].map { value($0, side) } ?? 1.5
    }

    /// 染色的 vibrantColorMatrix（4×5，列優先）的擬合律：七個量測色上準；NativeGlass.tintMatrix 拿不到系統的值才用它
    static func tintMatrix(_ c: NSColor, clear: Bool, dark: Bool) -> [Float] {
        let key = "\(clear ? "clear" : "regular")-\(dark ? "dark" : "light")"
        guard let law = tintLaws[key], let t = c.usingColorSpace(.sRGB) else { return [] }
        let rgb = [Double(t.redComponent), Double(t.greenComponent), Double(t.blueComponent)], alpha = Double(t.alphaComponent)
        var m = [Float](repeating: 0, count: 20)
        m[18] = Float(alpha)
        if rgb.max()! - rgb.min()! < 0.01 {   // 中性色（白、黑、灰）：對角矩陣
            let v = rgb[0]
            for i in 0..<3 { m[i * 5 + i] = Float(law.neutralDiag); m[i * 5 + 4] = Float(law.neutralBlack + (law.neutralWhite - law.neutralBlack) * v) }
            return m
        }
        func affine(_ a: [Double], _ r: [Double]) -> [Double] {
            var out = (0..<3).map { i in a[i * 4] * rgb[0] + a[i * 4 + 1] * rgb[1] + a[i * 4 + 2] * rgb[2] + a[i * 4 + 3] }
            // 殘差：每個樣本 exp(−(d／0.12)²) 加權
            var wsum = 0.0, acc = [0.0, 0.0, 0.0]
            for j in 0..<(law.samples.count / 3) {
                let d = sqrt((0..<3).map { pow(law.samples[j * 3 + $0] - rgb[$0], 2) }.reduce(0, +))
                let w = exp(-pow(d / 0.12, 2))
                wsum += w
                for i in 0..<3 { acc[i] += w * r[j * 3 + i] }
            }
            for i in 0..<3 { out[i] += acc[i] / max(1, wsum) }
            return out
        }
        let lo = affine(law.lowAffine, law.lowResidual), hi = affine(law.highAffine, law.highResidual)
        let lw = [0.2126, 0.7152, 0.0722]
        for i in 0..<3 {
            for j in 0..<3 { m[i * 5 + j] = Float((hi[i] - lo[i]) * lw[j]) }
            m[i * 5 + 4] = Float(lo[i])
        }
        return m
    }

    /// 把 NativeGlass 建好的 macOS 層樹換成 iOS 的參數（層樹的單位是 pt）
    /// 容器（GlassEffectContainer）：整組形狀共用一個 backdrop，尺寸規律用整組的最小／最大短邊（pt）
    static func apply(_ root: CALayer, clear: Bool, dark: Bool, groupSides: (min: Double, max: Double)? = nil) {
        let lk = look(clear: clear, dark: dark)
        walk(root) { l in
            guard "\(type(of: l))" == "CABackdropLayer", let fs = l.value(forKey: "filters") as? [NSObject],
                  let gi = fs.firstIndex(where: { "\($0.value(forKey: "type") ?? "")" == "glassBackground" }) else { return }
            // 這片玻璃裡的形狀（element 的大小；contents 模式要扣掉距離場四周補的那圈）
            var sides: [Double] = []
            walk(l) { e in
                guard "\(type(of: e))" == "CASDFElementLayer" else { return }
                var sz = e.bounds.size
                if "\(e.value(forKey: "mode") ?? "")" == "contents", let z = e.value(forKey: "contentsZeroValueDistance") as? Double {
                    sz.width += 2 * z; sz.height += 2 * z   // z 是負的
                }
                if sz.width > 0.5, sz.height > 0.5 { sides.append(Double(min(sz.width, sz.height))) }
            }
            let own = (sides.min() ?? Double(min(l.bounds.width, l.bounds.height)), sides.max() ?? sides.min() ?? Double(min(l.bounds.width, l.bounds.height)))
            let (sMin, sMax) = groupSides.map { ($0.min, $0.max) } ?? own   // 容器：整組一起
            let f = fs[gi]
            for (k, v) in lk.constants { f.setValue(v, forKey: k) }
            for (k, v) in lk.colors where v.count == 4 { f.setValue(CGColor(srgbRed: v[0], green: v[1], blue: v[2], alpha: v[3]), forKey: k) }
            for (k, c) in lk.curves where k.hasPrefix("input") { f.setValue(value(c, usesMinSide(k) ? sMin : sMax), forKey: k) }
            var nfs = fs; nfs[gi] = f
            l.setValue(nfs, forKey: "filters")
            if let mw = lk.curves["marginWidth"] { l.setValue(value(mw, sMax), forKey: "marginWidth") }
            // 這片玻璃的 @0 輸出範圍（染色矩陣由 NativeGlass.build 統一換：系統在作用中視窗算的那個）
            let maxOut = lk.curves["outputMaximum"].map { value($0, sMax) }
            walk(l.superlayer ?? l) { s in
                guard "\(type(of: s))" == "CASDFLayer", s.responds(to: NSSelectorFromString("effect")),
                      let fx = s.value(forKey: "effect") as? NSObject else { return }
                switch "\(type(of: fx))" {
                case "CASDFOutputEffect":
                    if let maxOut { fx.setValue(maxOut, forKey: "maximum"); s.setValue(fx, forKey: "effect") }
                default: break
                }
            }
            // @2 亮邊在 CABackdropLayer 的兄弟層（同一個玻璃 view 裡）
            for sib in l.superlayer?.sublayers ?? [] where sib !== l {
                walk(sib) { s in
                    guard "\(type(of: s))" == "CASDFLayer", s.responds(to: NSSelectorFromString("effect")),
                          let fx = s.value(forKey: "effect") as? NSObject, "\(type(of: fx))" == "CASDFKeyFillHighlightEffect" else { return }
                    for (k, v) in lk.highlight { fx.setValue(v, forKey: k) }
                    if let c = lk.curves["keySpread"] { fx.setValue(value(c, sMax), forKey: "keySpread") }
                    if let c = lk.curves["fillSpread"] { fx.setValue(value(c, sMax), forKey: "fillSpread") }
                    s.setValue(fx, forKey: "effect")
                }
            }
        }
    }

    private static func walk(_ l: CALayer, _ f: (CALayer) -> Void) {
        f(l)
        for s in l.sublayers ?? [] { walk(s, f) }
    }
}
