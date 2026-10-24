import SwiftUI

/// Logs the window geometry the layout depends on (frame, safe area, reserved regions, including
/// inactive ones) whenever it changes. Diagnostic: the simulator and the device can report the
/// cover display's camera differently, and only the device knows where the hole really is.
struct GeometryProbe: ViewModifier {
    let label: String

    func body(content: Content) -> some View {
        content.background {
            // Full window (ignoring the safe area), with a second reader inside it that does not.
            GeometryReader { proxy in
                let report = GeometryReport(label: label + "/full", proxy: proxy)
                GeometryReader { inner in
                    let innerReport = GeometryReport(label: label + "/inner", proxy: inner)
                    Color.clear.onChange(of: innerReport, initial: true) { _, new in
                        print(new.description)
                    }
                }
                .onChange(of: report, initial: true) { _, new in
                    print(new.description)
                }
            }
            .ignoresSafeArea()
        }
    }
}

struct GeometryReport: Equatable, CustomStringConvertible {
    struct Region: Equatable {
        var frame: CGRect
        var active: Bool
    }

    var label: String
    /// The proxy's frame in the window.
    var frame: CGRect
    var insets: EdgeInsets
    var divisions: [Region]
    var occlusions: [Region]

    init(label: String, proxy: GeometryProxy) {
        self.label = label
        frame = proxy.frame(in: .global)
        insets = proxy.safeAreaInsets
        divisions = proxy.reservedRegions(kind: .division, options: [.includeInactive])
            .map { Region(frame: $0.frame, active: $0.isActive) }
        occlusions = proxy.reservedRegions(kind: .occlusion, options: [.includeInactive])
            .map { Region(frame: $0.frame, active: $0.isActive) }
    }

    var description: String {
        func rect(_ r: CGRect) -> String {
            "(\(Int(r.minX.rounded())),\(Int(r.minY.rounded())) \(Int(r.width.rounded()))x\(Int(r.height.rounded())))"
        }
        func regions(_ list: [Region]) -> String {
            list.isEmpty ? "none" : list.map { region in
                // Local to the proxy, then in window coordinates.
                "\(rect(region.frame))→\(rect(region.frame.offsetBy(dx: frame.minX, dy: frame.minY)))\(region.active ? " active" : " inactive")"
            }.joined(separator: ", ")
        }
        return "[geometry] \(label): frame=\(rect(frame)) insets=t\(Int(insets.top)) l\(Int(insets.leading)) " +
            "b\(Int(insets.bottom)) r\(Int(insets.trailing)) division=\(regions(divisions)) occlusion=\(regions(occlusions))"
    }
}
