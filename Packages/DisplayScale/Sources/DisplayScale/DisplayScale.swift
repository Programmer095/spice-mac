// SPDX-License-Identifier: MIT
import CoreGraphics

/// Pure geometry shared by the window controller (which asks the guest for a
/// resolution) and the display view (which fits that resolution onto the drawable).
///
/// Two equations drive the zoom feature, with `P` = view points, `B` = backing scale,
/// `D = P·B` = drawable pixels, `G` = guest framebuffer and `Z` = zoom:
///
///   1. request side (host → guest):  `G = align(P·B / Z)`
///   2. render side  (guest → host):  `scale = snapDown(min(Dw/Gw, Dh/Gh))`
///
/// (2) already existed; zoom only changes (1), which is why rendering *and* the input
/// router's inverse mapping follow for free. Verified by `scalecheck`; no AppKit here.
public enum DisplayScale {

    // MARK: - Requested guest resolution

    /// Floor for a requested guest mode. An extreme zoom in a small window must not
    /// ask the guest for something no display driver will accept, or leave the guest
    /// desktop unusable. 640×480 is the universally safe minimum.
    public static let minimumGuest = CGSize(width: 640, height: 480)

    /// Sanity ceiling (QXL / virtio-gpu refuse far below this anyway).
    public static let maximumGuest = CGSize(width: 8192, height: 8192)

    /// Guest drivers dislike odd geometry: the QXL surface stride and most X/DRM
    /// mode tables want a width that is a multiple of 8 and an even height. We
    /// round DOWN, never up, so the requested mode always fits inside the drawable
    /// — rounding up would push the fit scale below Z and force a downscale.
    public static let widthGranularity: CGFloat = 8
    public static let heightGranularity: CGFloat = 2

    /// `G = align(P·B / Z)` — the guest resolution to request.
    public static func targetGuestSize(viewPoints: CGSize,
                                       backingScale: CGFloat,
                                       zoom: DisplayZoom) -> CGSize {
        let backing = backingScale > 0 ? backingScale : 1
        let factor = max(0.25, zoom.factor(backingScale: backing))
        return align(CGSize(width: viewPoints.width * backing / factor,
                            height: viewPoints.height * backing / factor))
    }

    /// Clamp into `minimumGuest ... maximumGuest`, then floor onto the granularity
    /// grid.
    public static func align(_ size: CGSize) -> CGSize {
        func snap(_ value: CGFloat, _ grid: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            guard value.isFinite else { return low }
            let clamped = min(max(value, low), high)
            return max(low, (clamped / grid).rounded(.down) * grid)
        }
        return CGSize(
            width: snap(size.width, widthGranularity, minimumGuest.width, maximumGuest.width),
            height: snap(size.height, heightGranularity, minimumGuest.height, maximumGuest.height))
    }

    // MARK: - Idempotence

    public static func nearlyEqual(_ a: CGSize, _ b: CGSize, tolerance: CGFloat = 1) -> Bool {
        abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// Whether a monitor-config request is worth sending. Every request costs the
    /// guest a real mode switch — a black flash, up to a second of reconfiguration
    /// — so skip the no-ops: the guest is already there, or we asked for exactly
    /// this already and it either honoured or refused us. The second rule leaves a
    /// guest that rounds our request to its own mode table alone rather than
    /// nagging it.
    public static func needsRequest(target: CGSize, current: CGSize,
                                    lastRequested: CGSize?) -> Bool {
        guard target.width > 0, target.height > 0 else { return false }
        if let lastRequested, nearlyEqual(target, lastRequested) { return false }
        return !nearlyEqual(target, current)
    }

    // MARK: - Render fit

    /// Largest uniform scale that fits the guest inside the drawable
    /// (aspect-preserving "fit with black bars"). Use `max` for cover/fill.
    public static func fitScale(guest: CGSize, drawable: CGSize) -> CGFloat {
        guard guest.width > 0, guest.height > 0,
              drawable.width > 0, drawable.height > 0 else { return 1 }
        return min(drawable.width / guest.width, drawable.height / guest.height)
    }

    /// Relative tolerance for snapping a magnification onto a whole number.
    public static let integerSnapTolerance: CGFloat = 0.02

    /// Snap a magnification DOWN onto a whole number when it sits within
    /// `tolerance` above one — never up, since the quad is `guest · scale` wide and
    /// centred, so a snap up would clip its edges. It costs at most `tolerance` of
    /// the drawable in extra letterbox and buys the exact integer magnification
    /// nearest-neighbour needs. Needed because `align` floors G, leaving the fit at
    /// `Z · (1 + ≤8/Gw)`.
    public static func snapDownToInteger(_ scale: CGFloat,
                                         tolerance: CGFloat = integerSnapTolerance) -> CGFloat {
        guard scale.isFinite, scale >= 1 else { return scale }   // never touch a downscale
        let whole = scale.rounded(.down)
        guard whole >= 1 else { return scale }
        return (scale / whole - 1) <= tolerance ? whole : scale
    }

    /// The scale handed to the renderer AND reported to the input router. Both must
    /// call this one function: if they ever disagree, the guest cursor drifts away
    /// from the macOS pointer.
    public static func renderScale(guest: CGSize, drawable: CGSize) -> CGFloat {
        snapDownToInteger(fitScale(guest: guest, drawable: drawable))
    }

    /// Nearest-neighbour is correct at any whole-number magnification: each guest
    /// pixel becomes an exact N×N block, so guest text stays crisp rather than
    /// bilinear-soft. N = 1 counts — a 1:1 presentation is a pure blit, and leaving
    /// it linear is what smeared it across the half-pixel offset
    /// `pixelAlignedOrigin` corrects. Fractional scales and downscales must stay
    /// linear or they alias badly.
    public static func usesNearestFilter(scale: CGFloat) -> Bool {
        scale >= 1 && abs(scale - scale.rounded()) < 0.0001
    }

    /// Sub-pixel correction that pulls the CENTRED guest quad onto whole drawable
    /// pixels, to be added to the renderer's `viewportOrigin`. The quad edge sits
    /// at `slack / 2` for `slack = drawable - guest · scale`, so odd slack lands it
    /// on a half pixel — which the linear sampler blurs and the input router's
    /// inverse mapping cannot see. Rounding gives one letterbox bar the odd pixel
    /// instead.
    public static func pixelAlignedOrigin(guest: CGSize, drawable: CGSize,
                                          scale: CGFloat) -> CGPoint {
        func correction(_ drawableSide: CGFloat, _ guestSide: CGFloat) -> CGFloat {
            let half = (drawableSide - guestSide * scale) / 2
            guard half.isFinite else { return 0 }
            return half.rounded() - half
        }
        return CGPoint(x: correction(drawable.width, guest.width),
                       y: correction(drawable.height, guest.height))
    }

    // MARK: - Window sizing

    /// Window CONTENT size in points that shows `guest` pixels at zoom Z on a
    /// display with backing scale B: `points = guest · Z / B`.
    ///
    /// Grown to `minimum` and then shrunk to `maximum`, both uniformly, so the
    /// guest aspect ratio survives either clamp (the shrink is applied last and
    /// wins).
    public static func windowContentPoints(guest: CGSize,
                                           zoom: DisplayZoom,
                                           backingScale: CGFloat,
                                           minimum: CGSize = CGSize(width: 640, height: 400),
                                           maximum: CGSize?) -> CGSize {
        let backing = backingScale > 0 ? backingScale : 1
        let factor = zoom.factor(backingScale: backing)
        guard guest.width > 0, guest.height > 0, factor > 0 else { return minimum }
        var width = guest.width * factor / backing
        var height = guest.height * factor / backing
        let grow = max(1, max(minimum.width / width, minimum.height / height))
        width *= grow
        height *= grow
        if let maximum, maximum.width > 0, maximum.height > 0 {
            let shrink = min(1, min(maximum.width / width, maximum.height / height))
            width *= shrink
            height *= shrink
        }
        return CGSize(width: width.rounded(.down), height: height.rounded(.down))
    }

    // MARK: - Stepping

    /// Step through the fixed ladder, returning the input unchanged at either end —
    /// which is what the menu validation uses to disable Zoom In / Zoom Out.
    ///
    /// `.automatic` first resolves to its current effective percentage, so zooming
    /// in on a Retina display goes Automatic (200%) → 300% rather than down to
    /// 100%. The clamp returns `zoom` itself, not the nearest rung: a mode has to
    /// clamp to the mode, or Zoom Out on a 1x screen would silently freeze
    /// Automatic into a fixed level.
    public static func step(_ zoom: DisplayZoom, by direction: Int,
                            backingScale: CGFloat) -> DisplayZoom {
        let current = Int((zoom.factor(backingScale: backingScale) * 100).rounded())
        if direction > 0 {
            return DisplayZoom.ladder.first { $0.rawValue > current } ?? zoom
        } else {
            return DisplayZoom.ladder.last { $0.rawValue < current } ?? zoom
        }
    }
}
