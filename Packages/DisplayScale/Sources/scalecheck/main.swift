// SPDX-License-Identifier: MIT
import CoreGraphics
import Foundation
import DisplayScale

let t = TestRunner()
print("DisplayScale checks")

/// A representative 14" MacBook Pro window: points, and the drawable it implies at
/// 2x.
let viewPoints = CGSize(width: 1512, height: 982)
func drawable(_ points: CGSize, _ backing: CGFloat) -> CGSize {
    CGSize(width: points.width * backing, height: points.height * backing)
}

// MARK: - DisplayZoom

t.test("automatic resolves to the backing scale, fixed levels do not") {
    t.expectClose(DisplayZoom.automatic.factor(backingScale: 2), 2)
    t.expectClose(DisplayZoom.automatic.factor(backingScale: 1), 1)
    t.expectClose(DisplayZoom.percent200.factor(backingScale: 1), 2)
    t.expectClose(DisplayZoom.percent200.factor(backingScale: 2), 2)
    t.expectClose(DisplayZoom.percent125.factor(backingScale: 2), 1.25)
    // A bogus backing scale must not produce a zero or negative factor.
    t.expectClose(DisplayZoom.automatic.factor(backingScale: 0), 1)
}

t.test("raw 0 is automatic, so a missing UserDefaults key reads as automatic") {
    t.expectEqual(DisplayZoom(rawValue: 0), .automatic)
    t.expectEqual(DisplayZoom(rawValue: 200), .percent200)
    t.expectEqual(DisplayZoom(rawValue: 137), nil)
    t.expectEqual(DisplayZoom.automatic.title, "Automatic")
    t.expectEqual(DisplayZoom.percent150.title, "150%")
    t.expect(!DisplayZoom.ladder.contains(.automatic), "automatic is a mode, not a rung")
}

// MARK: - Requested guest resolution

t.test("automatic asks for the window's POINT size on any display") {
    // In automatic mode the requested size does not depend on the backing scale at
    // all.
    let onRetina = DisplayScale.targetGuestSize(viewPoints: viewPoints, backingScale: 2, zoom: .automatic)
    let onLowDPI = DisplayScale.targetGuestSize(viewPoints: viewPoints, backingScale: 1, zoom: .automatic)
    t.expectSize(onRetina, CGSize(width: 1512, height: 982))
    t.expectSize(onLowDPI, onRetina)
}

t.test("fixed zoom divides the drawable") {
    func target(_ zoom: DisplayZoom, _ backing: CGFloat) -> CGSize {
        DisplayScale.targetGuestSize(viewPoints: viewPoints, backingScale: backing, zoom: zoom)
    }
    t.expectSize(target(.percent100, 2), CGSize(width: 3024, height: 1964))  // today's behaviour
    t.expectSize(target(.percent200, 2), CGSize(width: 1512, height: 982))
    t.expectSize(target(.percent150, 2), CGSize(width: 2016, height: 1308))  // 1309.33 -> 1308
    t.expectSize(target(.percent400, 2), CGSize(width: 752, height: 490))    // 756 -> 752 on the /8 grid
    // On a 1x display a fixed 200% halves the real pixels — the case automatic
    // avoids.
    t.expectSize(target(.percent200, 1), CGSize(width: 752, height: 490))
}

t.test("requested sizes land on the 8x2 grid and stay inside the clamps") {
    for pw in stride(from: 300.0, through: 2200.0, by: 37.0) {
        for backing in [1.0, 2.0] as [CGFloat] {
            for zoom in DisplayZoom.allCases {
                let size = DisplayScale.targetGuestSize(
                    viewPoints: CGSize(width: pw, height: pw * 0.63),
                    backingScale: backing, zoom: zoom)
                t.expect(size.width.truncatingRemainder(dividingBy: 8) == 0,
                         "width \(size.width) is not a multiple of 8")
                t.expect(size.height.truncatingRemainder(dividingBy: 2) == 0,
                         "height \(size.height) is not even")
                t.expect(size.width >= DisplayScale.minimumGuest.width
                         && size.height >= DisplayScale.minimumGuest.height,
                         "\(str(size)) is below the minimum guest mode")
                t.expect(size.width <= DisplayScale.maximumGuest.width
                         && size.height <= DisplayScale.maximumGuest.height,
                         "\(str(size)) is above the maximum guest mode")
            }
        }
    }
}

t.test("an extreme zoom in a tiny window floors at the minimum guest mode") {
    let tiny = DisplayScale.targetGuestSize(viewPoints: CGSize(width: 200, height: 150),
                                            backingScale: 2, zoom: .percent400)
    t.expectSize(tiny, DisplayScale.minimumGuest)
}

t.test("an enormous drawable is capped instead of asking for an impossible mode") {
    let huge = DisplayScale.targetGuestSize(viewPoints: CGSize(width: 8000, height: 6000),
                                            backingScale: 2, zoom: .percent100)
    t.expectSize(huge, DisplayScale.maximumGuest)
}

// MARK: - Round trip: request, then fit

t.test("once the guest honours the request the render scale IS the zoom") {
    for backing in [1.0, 2.0] as [CGFloat] {
        for zoom in DisplayZoom.ladder {
            let guest = DisplayScale.targetGuestSize(viewPoints: viewPoints,
                                                     backingScale: backing, zoom: zoom)
            // Skip the levels the minimum-guest floor caps (see the next check).
            guard guest.width > DisplayScale.minimumGuest.width,
                  guest.height > DisplayScale.minimumGuest.height else { continue }
            let scale = DisplayScale.renderScale(guest: guest,
                                                 drawable: drawable(viewPoints, backing))
            let z = zoom.factor(backingScale: backing)
            // The 8/2 grid floors G, so the raw fit is always >= Z; the snap pulls
            // whole-number zooms back onto Z exactly.
            t.expect(scale >= z - 0.0001, "scale \(scale) fell below Z=\(z)")
            t.expect(scale <= z * (1 + DisplayScale.integerSnapTolerance),
                     "scale \(scale) drifted more than the snap tolerance above Z=\(z)")
            if z >= 2, z == z.rounded() {
                t.expectClose(scale, z)
                t.expect(DisplayScale.usesNearestFilter(scale: scale),
                         "Z=\(z) should reach a pixel-exact integer magnification")
            }
        }
    }
}

t.test("the minimum guest mode caps the zoom instead of asking for an unusable one") {
    // The floor wins, so the effective magnification lands BELOW the requested Z
    // rather than leaving the guest desktop unusable — a deliberate cap, not a bug.
    let points = CGSize(width: 1512, height: 982)
    let guest = DisplayScale.targetGuestSize(viewPoints: points, backingScale: 1, zoom: .percent400)
    t.expectSize(guest, DisplayScale.minimumGuest)
    let scale = DisplayScale.renderScale(guest: guest, drawable: drawable(points, 1))
    t.expect(scale > 1 && scale < 4, "effective magnification should be capped, got \(scale)")
}

// MARK: - Integer snapping

t.test("the snap only ever pulls a magnification DOWN onto a whole number") {
    t.expectClose(DisplayScale.snapDownToInteger(2.008), 2)
    t.expectClose(DisplayScale.snapDownToInteger(4.008), 4)
    t.expectClose(DisplayScale.snapDownToInteger(1.005), 1)
    // Never up: 1.99 must stay 1.99, or the quad would overflow the drawable and
    // clip.
    t.expectClose(DisplayScale.snapDownToInteger(1.99), 1.99)
    t.expectClose(DisplayScale.snapDownToInteger(2.5), 2.5)
    t.expectClose(DisplayScale.snapDownToInteger(2.95), 2.95)
    t.expectClose(DisplayScale.snapDownToInteger(0.6), 0.6)
    t.expectClose(DisplayScale.snapDownToInteger(0.999), 0.999)
}

t.test("renderScale is deterministic — the renderer and the input router can't diverge") {
    let guest = CGSize(width: 1512, height: 982)
    let d = CGSize(width: 3024, height: 1964)
    let first = DisplayScale.renderScale(guest: guest, drawable: d)
    for _ in 0..<10 { t.expectClose(DisplayScale.renderScale(guest: guest, drawable: d), first) }
    t.expectClose(first, 2)
}

t.test("nearest-neighbour at ANY whole-number magnification, 1:1 included") {
    t.expect(DisplayScale.usesNearestFilter(scale: 2), "2x is exact pixel doubling")
    t.expect(DisplayScale.usesNearestFilter(scale: 3), "3x is exact pixel tripling")
    // 1:1 is a pure blit. Leaving it linear is what made odd-slack widths blurry.
    t.expect(DisplayScale.usesNearestFilter(scale: 1), "1:1 is a pure blit")
    t.expect(!DisplayScale.usesNearestFilter(scale: 2.5), "fractional must stay linear")
    t.expect(!DisplayScale.usesNearestFilter(scale: 0.5), "downscaling must stay linear")
}

t.test("the quad is nudged onto whole pixels when the letterbox slack is odd") {
    func edge(_ guest: CGSize, _ drawable: CGSize, _ scale: CGFloat) -> CGFloat {
        let o = DisplayScale.pixelAlignedOrigin(guest: guest, drawable: drawable, scale: scale)
        return (drawable.width - guest.width * scale) / 2 + o.x
    }
    // Odd slack: 1507 - 1504 = 3, so the centred edge sits at 1.5 and needs half a
    // pixel.
    let odd = DisplayScale.pixelAlignedOrigin(guest: CGSize(width: 1504, height: 982),
                                              drawable: CGSize(width: 1507, height: 982),
                                              scale: 1)
    t.expectClose(abs(odd.x), 0.5)
    t.expectClose(odd.y, 0)
    t.expectClose(edge(CGSize(width: 1504, height: 982),
                       CGSize(width: 1507, height: 982), 1).truncatingRemainder(dividingBy: 1), 0)
    let even = DisplayScale.pixelAlignedOrigin(guest: CGSize(width: 1504, height: 980),
                                               drawable: CGSize(width: 1508, height: 982),
                                               scale: 1)
    t.expectClose(even.x, 0)
    t.expectClose(even.y, 0)
    // Holds at a magnification too, across every slack a floored G can produce.
    for slack in stride(from: 0.0, through: 7.0, by: 1.0) {
        for scale in [1.0, 2.0, 3.0] as [CGFloat] {
            let guest = CGSize(width: 1000, height: 600)
            let drawable = CGSize(width: guest.width * scale + slack,
                                  height: guest.height * scale)
            let e = edge(guest, drawable, scale)
            t.expect(abs(e - e.rounded()) < 0.0001,
                     "slack \(slack) at \(scale)x left the quad on \(e)")
        }
    }
}

t.test("aspect-fit letterboxes rather than cropping") {
    // A 16:9 guest in a 4:3 drawable fits by width.
    t.expectClose(DisplayScale.fitScale(guest: CGSize(width: 1920, height: 1080),
                                        drawable: CGSize(width: 1920, height: 1440)), 1)
    t.expectClose(DisplayScale.fitScale(guest: .zero, drawable: CGSize(width: 100, height: 100)), 1)
}

// MARK: - Idempotence

t.test("a redundant monitor-config is suppressed") {
    let target = CGSize(width: 1512, height: 982)
    t.expect(!DisplayScale.needsRequest(target: target, current: target, lastRequested: nil),
             "no request when the guest is already at the target")
    // Within a pixel counts as already there.
    t.expect(!DisplayScale.needsRequest(target: target,
                                        current: CGSize(width: 1512, height: 983),
                                        lastRequested: nil),
             "a one-pixel difference is not worth a mode switch")
    // We already asked for exactly this and the guest rounded it — don't nag.
    t.expect(!DisplayScale.needsRequest(target: target,
                                        current: CGSize(width: 1440, height: 900),
                                        lastRequested: target),
             "re-asking for a size the guest already refused only re-flashes the screen")
    t.expect(DisplayScale.needsRequest(target: target,
                                       current: CGSize(width: 1920, height: 1080),
                                       lastRequested: CGSize(width: 1920, height: 1080)),
             "a new target must be requested")
    t.expect(!DisplayScale.needsRequest(target: .zero, current: target, lastRequested: nil),
             "a degenerate target is never requested")
}

// MARK: - Window sizing (the no-agent path)

t.test("window points = guest x Z / B") {
    t.expectSize(DisplayScale.windowContentPoints(guest: CGSize(width: 1512, height: 982),
                                                  zoom: .percent200, backingScale: 2, maximum: nil),
                 CGSize(width: 1512, height: 982))
    // Retina, 100%: the guest maps 1:1 onto physical pixels, so half the points.
    t.expectSize(DisplayScale.windowContentPoints(guest: CGSize(width: 1512, height: 982),
                                                  zoom: .percent100, backingScale: 2, maximum: nil),
                 CGSize(width: 756, height: 491))
    // A 1x monitor in automatic: points == guest pixels.
    t.expectSize(DisplayScale.windowContentPoints(guest: CGSize(width: 1920, height: 1080),
                                                  zoom: .automatic, backingScale: 1, maximum: nil),
                 CGSize(width: 1920, height: 1080))
}

t.test("window sizing clamps uniformly so the guest aspect ratio survives") {
    // Grown to the minimum.
    let grown = DisplayScale.windowContentPoints(guest: CGSize(width: 320, height: 240),
                                                 zoom: .percent100, backingScale: 2, maximum: nil)
    t.expectSize(grown, CGSize(width: 640, height: 480))
    // Shrunk to fit the screen.
    let shrunk = DisplayScale.windowContentPoints(guest: CGSize(width: 1920, height: 1080),
                                                  zoom: .percent200, backingScale: 2,
                                                  maximum: CGSize(width: 1512, height: 900))
    t.expectSize(shrunk, CGSize(width: 1512, height: 850))
    t.expect(abs(shrunk.width / shrunk.height - 1920.0 / 1080.0) < 0.01,
             "aspect ratio drifted: \(str(shrunk))")
}

// MARK: - Stepping

t.test("zoom in/out steps away from automatic's CURRENT effective level") {
    t.expectEqual(DisplayScale.step(.automatic, by: 1, backingScale: 2), .percent300)
    t.expectEqual(DisplayScale.step(.automatic, by: -1, backingScale: 2), .percent150)
    t.expectEqual(DisplayScale.step(.automatic, by: 1, backingScale: 1), .percent125)
    t.expectEqual(DisplayScale.step(.percent150, by: 1, backingScale: 2), .percent200)
    t.expectEqual(DisplayScale.step(.percent150, by: -1, backingScale: 2), .percent125)
}

t.test("stepping clamps to the INPUT at both ends, modes included") {
    t.expectEqual(DisplayScale.step(.percent400, by: 1, backingScale: 2), .percent400)
    t.expectEqual(DisplayScale.step(.percent100, by: -1, backingScale: 2), .percent100)
    // A mode clamps to the mode: on a 1x screen Automatic already sits at the bottom
    // rung, and returning `.percent100` there would freeze it into a fixed level.
    t.expectEqual(DisplayScale.step(.automatic, by: -1, backingScale: 1), .automatic)
    t.expectEqual(DisplayScale.step(.automatic, by: 1, backingScale: 4), .automatic)
}

// MARK: - Crossing between displays

t.test("automatic asks for the SAME guest size on either screen, so a move is free") {
    // Why an Automatic drag costs no mode switch: Z tracks B, so P·B/Z is P on both.
    let onLowDPI = DisplayScale.targetGuestSize(viewPoints: viewPoints,
                                                backingScale: 1, zoom: .automatic)
    let onRetina = DisplayScale.targetGuestSize(viewPoints: viewPoints,
                                                backingScale: 2, zoom: .automatic)
    t.expectSize(onLowDPI, onRetina)
    // The two fixed levels that coincide with it, one per screen.
    t.expectSize(onLowDPI, DisplayScale.targetGuestSize(viewPoints: viewPoints,
                                                        backingScale: 1, zoom: .percent100))
    t.expectSize(onRetina, DisplayScale.targetGuestSize(viewPoints: viewPoints,
                                                        backingScale: 2, zoom: .percent200))
    t.expect(!DisplayScale.needsRequest(target: onRetina, current: onLowDPI,
                                        lastRequested: onLowDPI),
             "an automatic move should not cost a guest mode switch")
}

t.test("a FIXED level does need a new guest resolution on a move") {
    // A fixed level is absolute, so the target moves with the backing scale and the
    // request must go out. The level is never rewritten to hide that.
    for zoom in [DisplayZoom.percent100, .percent150, .percent200] {
        let before = DisplayScale.targetGuestSize(viewPoints: viewPoints,
                                                  backingScale: 2, zoom: zoom)
        let after = DisplayScale.targetGuestSize(viewPoints: viewPoints,
                                                 backingScale: 1, zoom: zoom)
        t.expect(!DisplayScale.nearlyEqual(before, after),
                 "\(zoom.title): expected a different target, got \(str(before)) both times")
        t.expect(DisplayScale.needsRequest(target: after, current: before, lastRequested: before),
                 "\(zoom.title): a screen move must re-request")
    }
}

t.finishAndExit()
