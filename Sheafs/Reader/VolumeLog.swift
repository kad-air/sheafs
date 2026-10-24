import Foundation
import Observation
import os

/// The volume-button page turner's diagnostic log: every line goes to the unified log (category
/// `volume`, public, so Console.app shows it from a TestFlight build) AND to a small in-memory
/// buffer that Settings → About → Volume Button Log shows and copies, so a device run can be read
/// without a Mac. Lasts for the life of the process.
@Observable
final class VolumeLog {
    static let shared = VolumeLog()
    private static let limit = 300

    private(set) var lines: [String] = []
    @ObservationIgnored private let log = Logger(subsystem: "io.sheafs.reader", category: "volume")
    @ObservationIgnored private let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    func note(_ line: String) {
        log.notice("[volume] \(line, privacy: .public)")
        lines.append("\(clock.string(from: Date())) \(line)")
        if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit) }
    }

    func clear() { lines.removeAll() }
}
