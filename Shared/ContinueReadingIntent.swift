import AppIntents
import Foundation

// Compiled into BOTH the app and the widget extension (see project.yml): the extension's control
// names the intent, the app runs it. 🔴 A FOREGROUND intent runs in the app's process (the system
// brings the app up first), so it opens the book directly. A background intent returning an
// `OpenURLIntent` from the extension did nothing from Control Center: the intent ran in the
// extension and the system never opened the link (openAppWhenRun: NO in its policy).

/// What the app does on the control's press; `SheafsApp` sets it at launch, before any intent
/// can arrive.
nonisolated enum ContinueReading {
    @MainActor static var handler: (@MainActor () -> Void)?
}

/// The control's action, and a Shortcuts action under the app's name: opens the book read last
/// (the library when there is none).
nonisolated struct ContinueReadingIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Reading"
    static let description = IntentDescription("Opens the book you read last.")
    static let supportedModes: IntentModes = .foreground

    func perform() async throws -> some IntentResult {
        await MainActor.run { ContinueReading.handler?() }
        return .result()
    }
}
