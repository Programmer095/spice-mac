// SPDX-License-Identifier: MIT
import CoreGraphics

/// Display zoom: **Z = host physical pixels per guest pixel**.
///
/// The client asks the guest agent for `viewPoints * backingScale / Z`, so every
/// guest pixel ends up occupying a Z×Z block of physical pixels — at Z = 2 a Retina
/// Mac shows guest UI at a comfortable size *and* the guest renders a quarter of the
/// pixels. `.automatic` is a mode rather than a frozen number: it resolves to the
/// window's current `backingScaleFactor`, so the requested resolution tracks the
/// window's POINT size and a drag between screens needs no reconfiguration.
///
/// The raw value is the percentage, 0 meaning automatic, so a missing
/// `UserDefaults` key (`integer(forKey:)` → 0) naturally reads as `.automatic`.
public enum DisplayZoom: Int, CaseIterable, Sendable {
    case automatic  = 0
    case percent100 = 100
    case percent125 = 125
    case percent150 = 150
    case percent200 = 200
    case percent300 = 300
    case percent400 = 400

    /// The fixed levels in ascending order — the menu listing and the zoom ladder.
    /// `.automatic` is not a rung: it is a mode that stepping resolves away from.
    public static let ladder: [DisplayZoom] =
        [.percent100, .percent125, .percent150, .percent200, .percent300, .percent400]

    public var title: String {
        self == .automatic ? "Automatic" : "\(rawValue)%"
    }

    /// Z for a window on a display with this backing scale. Resolve it at every use
    /// site: caching would freeze `.automatic` at the scale it happened to be read
    /// on.
    public func factor(backingScale: CGFloat) -> CGFloat {
        let backing = backingScale > 0 ? backingScale : 1
        return self == .automatic ? backing : CGFloat(rawValue) / 100
    }
}
