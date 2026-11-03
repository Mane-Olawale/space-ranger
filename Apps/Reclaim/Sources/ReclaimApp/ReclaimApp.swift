// Reclaim.app entry point — Phase 0: an empty window (PLAN.md §6 Phase 0). The real scenes, AppModel and
// onboarding arrive in Phase 4.

import SwiftUI

@main
struct ReclaimApp: App {
    var body: some Scene {
        WindowGroup("Reclaim") {
            Color.clear
                .frame(minWidth: 640, minHeight: 400)
        }
    }
}
