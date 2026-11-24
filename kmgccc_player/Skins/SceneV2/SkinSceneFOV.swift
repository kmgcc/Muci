import SwiftUI

/// `fov` — a lens edge for a whole subtree, strongest in the corners and absent inside `start`.
///
/// `distortion` (−0.6…0.6) stretches the edges outward like a wide-angle lens; `chromatic`
/// (points) spreads overlapping wavelength bands along the radius. `blur` (points)
/// is the Gaussian radius at the corners, growing from zero at `start` (0…1 of the half-diagonal).
/// `scale` is the share of resolution the passes run at; the point radii are multiplied by it.
enum SkinSceneFOV {
    static func apply(_ view: AnyView, filter: SkinValue, enabled: Bool, scale: Double = 1) -> AnyView {
        let distortion = min(0.6, max(-0.6, filter[member: "distortion"].number(0.2)))
        let chromaticPoints = max(0, min(24, filter[member: "chromatic"].number(1.5)))
        let blurPoints = max(0, min(32, filter[member: "blur"].number(6)))
        let chromatic = chromaticPoints * scale
        let blur = blurPoints * scale
        let start = filter[member: "start"].number(0.45).clamped01
        let reach = ceil(max(blur, chromatic)) + 1
        let library = ShaderLibrary.default
        // The passes stay in place at zero and only switch off, so turning a setting down to
        // nothing keeps the subtree's identity: a pass that came and went would remount every
        // node under it, and the scene would lose its springs and state.
        let lens = enabled && (abs(distortion) > 0.001 || chromaticPoints > 0.05)
        let blurs = enabled && blurPoints > 0.4
        // Every pass samples inside the frame only, so the subtree is clipped to it first. Left
        // unclipped, lines and comets far off screen grow the offscreen the passes render into,
        // and its size changes whenever one arrives or leaves.
        var view = AnyView(view.clipped())
        view = SkinSceneFilters.padded(view, reach: reach) { padded in
            padded.visualEffect { effect, proxy in
                // The stretch samples up to `0.35 * |distortion|` of the half size away from
                // the pixel (at the corners). The offset must cover it, or a partial redraw
                // reads nothing there and text near the left and right edges is cut off.
                let stretch = 0.35 * abs(distortion) * 1.05
                return effect.layerEffect(
                    library.skinFxLens(.float2(proxy.size), .float(reach), .float(distortion), .float(chromatic), .float(start)),
                    maxSampleOffset: CGSize(width: ceil(proxy.size.width / 2 * stretch) + reach, height: ceil(proxy.size.height / 2 * stretch) + reach),
                    isEnabled: lens)
            }
        }
        for axis in [CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)] {
            view = SkinSceneFilters.padded(view, reach: reach) { padded in
                padded.visualEffect { effect, proxy in
                    effect.layerEffect(
                        library.skinFxEdgeBlur(.float2(proxy.size), .float(reach), .float2(axis.x, axis.y), .float(blur), .float(start)),
                        maxSampleOffset: CGSize(width: reach * axis.x, height: reach * axis.y),
                        isEnabled: blurs)
                }
            }
        }
        return view
    }
}
