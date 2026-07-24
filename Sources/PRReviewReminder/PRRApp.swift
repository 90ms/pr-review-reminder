import SwiftUI
import PRRCore

@main
struct PRRApp: App {
    @StateObject private var app = AppState()

    init() {
        // Headless diagnostics: `PRReviewReminder --doctor` prints dependency
        // resolution and exits. Useful for verifying CLI discovery in a GUI-like
        // (Finder-launched) environment without inherited terminal PATH.
        if CommandLine.arguments.contains("--doctor") {
            PRRApp.runDoctorAndExit()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(app)
                .task { await app.bootstrap() }
        } label: {
            let count = app.pendingCount
            if count > 0 {
                Text("\(count)")
                Image(systemName: "checklist")
            } else {
                Image(systemName: "checklist")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(app)
        }

        Window(app.l("pr_detail"), id: "pr-detail") {
            PRDetailView()
                .environmentObject(app)
        }
        .windowResizability(.contentMinSize)

        Window(app.l("feedback"), id: "feedback") {
            FeedbackView()
                .environmentObject(app)
        }
        .windowResizability(.contentSize)

        Window(app.l("history"), id: "history") {
            HistoryView()
                .environmentObject(app)
        }
        .windowResizability(.contentMinSize)
    }

    private static func runDoctorAndExit() -> Never {
        let runner = SystemProcessRunner()
        let locator = ToolLocator(runner: runner)
        let doctor = DependencyDoctor(runner: runner, locator: locator)
        let sema = DispatchSemaphore(value: 0)
        // Detached so it does not inherit the MainActor; otherwise the semaphore
        // wait on the main thread would deadlock the async work.
        Task.detached {
            let status = await doctor.diagnose()
            let gh = await locator.path(for: "gh")
            let claude = await locator.path(for: "claude")
            let codex = await locator.path(for: "codex")
            print("PR Review Reminder — doctor")
            print("  gh:     \(gh ?? "NOT FOUND")  authed=\(status.ghAuthenticated) login=\(status.ghLogin ?? "-")")
            print("  claude: \(claude ?? "NOT FOUND")")
            print("  codex:  \(codex ?? "NOT FOUND")")
            print("  usable: \(status.isUsable)")
            for p in status.problems { print("  ! \(p)") }
            sema.signal()
        }
        sema.wait()
        exit(0)
    }
}
