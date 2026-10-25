import SwiftUI

/// A reserved region of the display (the iPhone Duo's fold or its cover camera) as plain values.
struct DisplayRegion: Equatable {
    var frame: CGRect
    var isActive: Bool
}

extension GeometryProxy {
    /// The fold, local to the proxy. `reservedRegions` is iOS 27.1, which is the iPhone Duo's own
    /// release: every other iPhone and iPad goes from 27.0 to 27.2, and on 27.0 there is no fold
    /// to report. `includeInactive` adds the fold of a display lying flat.
    func divisions(includeInactive: Bool = true) -> [DisplayRegion] {
        guard #available(iOS 27.1, *) else { return [] }
        let options: ReservedRegion.QueryOptions = includeInactive ? [.includeInactive] : []
        return reservedRegions(kind: .division, options: options).map { DisplayRegion(frame: $0.frame, isActive: $0.isActive) }
    }

    /// The camera hole and the strip around it on the Duo's cover display, local to the proxy;
    /// none before iOS 27.1 (see `divisions`).
    func occlusions(includeInactive: Bool = true) -> [DisplayRegion] {
        guard #available(iOS 27.1, *) else { return [] }
        let options: ReservedRegion.QueryOptions = includeInactive ? [.includeInactive] : []
        return reservedRegions(kind: .occlusion, options: options).map { DisplayRegion(frame: $0.frame, isActive: $0.isActive) }
    }
}
