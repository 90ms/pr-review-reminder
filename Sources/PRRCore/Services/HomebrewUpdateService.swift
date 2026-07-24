import Foundation

public struct AppUpdateInfo: Sendable, Equatable {
    public let currentVersion: String
    public let latestVersion: String
    public let updateAvailable: Bool

    public init(currentVersion: String, latestVersion: String, updateAvailable: Bool) {
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.updateAvailable = updateAvailable
    }
}

public enum HomebrewUpdateError: LocalizedError, Sendable, Equatable {
    case commandFailed(String)
    case invalidResponse
    case notInstalled

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let message): return message
        case .invalidResponse: return "Homebrew returned an invalid version response."
        case .notInstalled: return "PR Review Reminder is not installed with Homebrew."
        }
    }
}

public struct HomebrewUpdateService: Sendable {
    public static let formula = "90ms/tap/pr-review-reminder"

    private let runner: ProcessRunning

    public init(runner: ProcessRunning) {
        self.runner = runner
    }

    public static func updateCommand(brew: String) -> Command {
        Command(executable: brew, arguments: ["update"], timeout: 300)
    }

    public static func infoCommand(brew: String) -> Command {
        Command(
            executable: brew,
            arguments: ["info", "--json=v1", formula],
            timeout: 60
        )
    }

    public static func upgradeCommand(brew: String) -> Command {
        Command(
            executable: brew,
            arguments: ["upgrade", formula],
            timeout: 1_800
        )
    }

    public static func launcherPath(for brew: String) -> String {
        URL(fileURLWithPath: brew)
            .deletingLastPathComponent()
            .appendingPathComponent("pr-review-reminder")
            .path
    }

    public static func parseInfo(_ raw: String, bundleVersion: String?) throws -> AppUpdateInfo {
        struct FormulaInfo: Decodable {
            struct Versions: Decodable { let stable: String }
            struct Installed: Decodable { let version: String }

            let versions: Versions
            let installed: [Installed]
        }

        guard let data = raw.data(using: .utf8),
              let formula = try? JSONDecoder().decode([FormulaInfo].self, from: data).first else {
            throw HomebrewUpdateError.invalidResponse
        }
        let installed = formula.installed.first?.version
        guard installed != nil else {
            throw HomebrewUpdateError.notInstalled
        }
        guard let current = normalized(bundleVersion) ?? normalized(installed),
              let latest = normalized(formula.versions.stable) else {
            throw HomebrewUpdateError.invalidResponse
        }
        return AppUpdateInfo(
            currentVersion: current,
            latestVersion: latest,
            updateAvailable: compareVersions(current, latest) == .orderedAscending
        )
    }

    public func check(brew: String, bundleVersion: String?) async throws -> AppUpdateInfo {
        let update = try await runner.run(Self.updateCommand(brew: brew))
        guard update.succeeded else {
            throw HomebrewUpdateError.commandFailed(
                update.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let info = try await runner.run(Self.infoCommand(brew: brew))
        guard info.succeeded else {
            throw HomebrewUpdateError.commandFailed(
                info.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return try Self.parseInfo(info.stdout, bundleVersion: bundleVersion)
    }

    public func upgrade(brew: String) async throws {
        let result = try await runner.run(Self.upgradeCommand(brew: brew))
        guard result.succeeded else {
            throw HomebrewUpdateError.commandFailed(
                result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let launcher = Self.launcherPath(for: brew)
        let relink = try await runner.run(
            Command(executable: launcher, arguments: ["--install-app"], timeout: 30)
        )
        guard relink.succeeded else {
            throw HomebrewUpdateError.commandFailed(
                relink.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private static func normalized(_ version: String?) -> String? {
        guard let version else { return nil }
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^\d+\.\d+\.\d+(?:[-.][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil else {
            return nil
        }
        return trimmed
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func components(_ value: String) -> [Int] {
            value.split(separator: "-", maxSplits: 1)[0]
                .split(separator: ".")
                .prefix(3)
                .map { Int($0) ?? 0 }
        }
        let left = components(lhs)
        let right = components(rhs)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }
}
