import SwiftUI
import WidgetKit

/// A control for the Lock Screen's corner buttons, Control Center and the Action button: the Sheafs
/// icon in one colour. A press runs `ContinueReadingIntent` (Shared/) in the app, which opens the
/// book read last, or the library when there is no book yet.
///
/// The icon is the custom symbol `sheafs` (Assets.xcassets/sheafs.symbolset): controls only take
/// symbol images, which the system tints and scales itself. `scripts/gen-symbol` draws it.
struct ContinueReadingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: RecentBookShelf.controlKind) {
            ControlWidgetButton(action: ContinueReadingIntent()) {
                // Control Center's wide tile shows the title; the Lock Screen only the symbol.
                Label(RecentBookShelf.shared?.read()?.title ?? "Continue Reading", image: "sheafs")
                    .controlWidgetActionHint("Continue Reading")
            }
        }
        .displayName("Continue Reading")
        .description("Opens the book you read last.")
    }
}
