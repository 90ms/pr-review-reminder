import Darwin
import Foundation

public struct UnexpectedTerminationReport: Sendable, Equatable {
    public let startedAt: Date
    public let appVersion: String

    public var issueTitle: String {
        "[Crash] Unexpected termination in \(appVersion)"
    }

    public var issueBody: String {
        """
        ## What happened

        PR Review Reminder detected that its previous session did not exit cleanly.

        ## Diagnostic metadata

        - App version: \(appVersion)
        - Session started: \(startedAt.ISO8601Format())
        - macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)

        ## Additional context

        Please describe what you were doing immediately before the app stopped.

        > This draft contains only app/session metadata. Review it before submitting.
        """
    }
}

public final class SessionHealthStore: @unchecked Sendable {
    private struct Session: Codable {
        let pid: Int32
        let startedAt: Date
        let appVersion: String
    }

    private let store: KeyValueStore
    private let key: String

    public init(
        store: KeyValueStore = UserDefaults.standard,
        key: String = "app.activeSession"
    ) {
        self.store = store
        self.key = key
    }

    public func beginSession(
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        appVersion: String,
        now: Date = Date()
    ) -> UnexpectedTerminationReport? {
        beginSession(
            pid: pid,
            appVersion: appVersion,
            now: now,
            isProcessRunning: SessionHealthStore.isProcessRunning
        )
    }

    public func beginSession(
        pid: Int32,
        appVersion: String,
        now: Date = Date(),
        isProcessRunning: (Int32) -> Bool
    ) -> UnexpectedTerminationReport? {
        let previous = load()
        save(Session(pid: pid, startedAt: now, appVersion: appVersion))
        guard let previous,
              previous.pid != pid,
              !isProcessRunning(previous.pid)
        else { return nil }
        return UnexpectedTerminationReport(
            startedAt: previous.startedAt,
            appVersion: previous.appVersion
        )
    }

    public func endSession(pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        guard load()?.pid == pid else { return }
        store.set(nil, forKey: key)
    }

    private func load() -> Session? {
        guard let data = store.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    private func save(_ session: Session) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        store.set(data, forKey: key)
    }

    private static func isProcessRunning(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
