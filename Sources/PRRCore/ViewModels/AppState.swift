import Foundation
import SwiftUI

public enum LoadState: Equatable {
    case idle
    case loading
    case done
    case cancelled
    case timedOut
    case failed(String)

    public var isFailed: Bool { if case .failed = self { return true }; return false }
}

public enum DetailLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

public enum AppUpdateStage: Equatable {
    case idle
    case refreshingTap
    case readingVersion
    case upgradingFormula
    case relinkingApplication
    case restartRequired
    case restarting
    case cancelling
    case cancelled
    case failed(operation: HomebrewUpdateOperation?, message: String)

    public var isBusy: Bool {
        switch self {
        case .refreshingTap, .readingVersion, .upgradingFormula,
             .relinkingApplication, .restarting, .cancelling:
            return true
        default:
            return false
        }
    }
}

public struct RefreshDiagnostic: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable { case success, failed }
    public let date: Date
    public let outcome: Outcome
    public let itemCount: Int
    public let retryCount: Int
    public let reachedSearchLimit: Bool
    public let rateLimited: Bool
    public let message: String?
}

public enum RefreshTrigger: Sendable, Equatable {
    case manual
    case scheduled
}

/// A pull request plus its (optional) analysis and fetched details.
public struct PRItem: Identifiable, Equatable {
    public var pr: PullRequest
    public var details: PRDetails?
    public var detailsState: DetailLoadState = .idle
    public var analysis: Analysis?
    public var usage: AIUsage?
    public var state: LoadState = .idle
    public var id: String { pr.id }

    public init(pr: PullRequest) { self.pr = pr }
}

/// Top-level observable state. Orchestrates dependency diagnosis, collection,
/// analysis, and user-triggered publishing. Runs on the main actor.
@MainActor
public final class AppState: ObservableObject {
    @Published public private(set) var items: [PRItem] = []
    @Published public private(set) var status: DependencyStatus?
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastRun: Date?
    @Published public private(set) var nextRun: Date?
    @Published public private(set) var scheduleRuns: [ScheduleRunRecord]
    @Published public private(set) var lastRefreshDiagnostic: RefreshDiagnostic?
    @Published public var lastError: String?
    @Published public var settings: AppSettings
    @Published public private(set) var settingsStorageDiagnostic: StorageDiagnostic
    @Published public private(set) var historyStorageDiagnostic: StorageDiagnostic
    @Published public private(set) var updateInfo: AppUpdateInfo?
    @Published public private(set) var updateStage: AppUpdateStage = .idle
    /// PR currently shown in the detail window.
    @Published public var selectedItemID: String?
    /// Persisted review history, newest first.
    @Published public private(set) var historyItems: [ReviewRecord] = []
    /// Persisted review currently shown in the read-only history detail window.
    @Published public var selectedHistoryID: String?

    private let runner: ProcessRunning
    private let locator: ToolLocator
    private let settingsStore: SettingsStore
    private let history: HistoryStore
    private let scheduleRunStore: ScheduleRunStore

    private var ghPath: String?
    private var claudePath: String?
    private var codexPath: String?
    private var brewPath: String?
    private var scheduleTimer: Timer?
    private var didBootstrap = false
    private var reviewTasks: [String: Task<Void, Never>] = [:]
    private var updateTask: Task<Void, Never>?

    public init(runner: ProcessRunning = SystemProcessRunner(),
                settingsStore: SettingsStore = SettingsStore(),
                history: HistoryStore = HistoryStore(),
                scheduleRunStore: ScheduleRunStore = ScheduleRunStore(),
                autoBootstrap: Bool = true) {
        self.runner = runner
        self.locator = ToolLocator(runner: runner)
        self.settingsStore = settingsStore
        self.history = history
        self.scheduleRunStore = scheduleRunStore
        self.settings = settingsStore.load()
        self.settingsStorageDiagnostic = settingsStore.diagnostic
        self.historyStorageDiagnostic = history.diagnostic
        self.historyItems = self.settings.historyEnabled ? history.all() : []
        self.scheduleRuns = scheduleRunStore.all()
        // Start diagnosis and scheduling at launch, not only when the popover opens.
        // Tests may opt out to drive lifecycle transitions deterministically.
        if autoBootstrap {
            Task { await self.bootstrap() }
        }
    }

    /// Cumulative usage across all recorded reviews.
    public func historyTotals() -> (tokens: Int, costUSD: Double, count: Int) {
        settings.historyEnabled ? history.totals() : (0, 0, 0)
    }

    public func deleteHistory(id: String) {
        history.delete(id: id)
        historyStorageDiagnostic = history.diagnostic
        historyItems = history.all()
    }

    public func deleteAllHistory() {
        history.deleteAll()
        historyStorageDiagnostic = history.diagnostic
        historyItems = []
        selectedHistoryID = nil
    }

    public var pendingCount: Int { items.count }

    /// Localization helper bound to the selected app language.
    public var l: L10n { L10n(language: settings.appLanguage) }

    public var selectedItem: PRItem? { items.first { $0.id == selectedItemID } }
    public var selectedHistoryRecord: ReviewRecord? {
        historyItems.first { $0.id == selectedHistoryID }
    }

    public func select(_ item: PRItem) { selectedItemID = item.id }
    public func selectHistory(_ record: ReviewRecord) { selectedHistoryID = record.id }

    /// Promotes a history record to the current work list for a fresh review.
    ///
    /// The persisted details are deliberately not reused: fetching details here
    /// ensures the review runs against the PR's current head and current diff.
    @discardableResult
    public func prepareReReview(from record: ReviewRecord) async -> String? {
        if ghPath == nil {
            await diagnose()
        }
        guard let ghPath else {
            lastError = "gh is not ready."
            return nil
        }

        let pr = record.pullRequest
        do {
            let details = try await GitHubService(runner: runner, ghPath: ghPath).fetchDetails(pr)
            var item = PRItem(pr: pr)
            item.details = details
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = item
            } else {
                items.insert(item, at: 0)
            }
            selectedItemID = item.id
            lastError = nil
            return item.id
        } catch {
            lastError = "\(error)"
            return nil
        }
    }

    // MARK: - Lifecycle

    public func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        Notifier.requestAuthorization()
        await diagnose()
        scheduleNextRun()
    }

    public func diagnose() async {
        let doctor = DependencyDoctor(runner: runner, locator: locator)
        let status = await doctor.diagnose()
        self.status = status
        self.ghPath = await locator.path(for: "gh")
        self.claudePath = await locator.path(for: "claude")
        self.codexPath = await locator.path(for: "codex")
        self.brewPath = await locator.path(for: "brew")
    }

    // MARK: - Settings

    @discardableResult
    public func saveSettings() -> Bool {
        settingsStore.save(settings)
        settingsStorageDiagnostic = settingsStore.diagnostic
        if settings.historyEnabled {
            history.applyRetention(days: settings.historyRetentionDays)
            historyStorageDiagnostic = history.diagnostic
            historyItems = history.all()
        } else {
            historyItems = []
            selectedHistoryID = nil
        }
        scheduleNextRun()
        return !settingsStorageDiagnostic.health.isFailure
    }

    public func checkForUpdates() async {
        guard !updateStage.isBusy else { return }
        guard let brewPath else {
            updateStage = .failed(operation: nil, message: l("update_homebrew_only"))
            return
        }
        let service = HomebrewUpdateService(runner: runner)
        do {
            updateStage = .refreshingTap
            try await service.refreshDefinitions(brew: brewPath)
            updateStage = .readingVersion
            updateInfo = try await service.readInfo(
                brew: brewPath,
                bundleVersion: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String
            )
            updateStage = .idle
        } catch is CancellationError {
            updateStage = .cancelled
        } catch {
            updateStage = updateFailure(error)
        }
    }

    public func installUpdate() async {
        guard !updateStage.isBusy else { return }
        guard let brewPath, let info = updateInfo, info.updateAvailable else { return }
        let service = HomebrewUpdateService(runner: runner)
        do {
            updateStage = .upgradingFormula
            try await service.upgradeFormula(brew: brewPath)
            updateStage = .relinkingApplication
            try await service.relinkApplication(brew: brewPath)
            updateInfo = AppUpdateInfo(
                currentVersion: info.latestVersion,
                latestVersion: info.latestVersion,
                updateAvailable: false
            )
            updateStage = .restartRequired
        } catch is CancellationError {
            updateStage = .cancelled
        } catch {
            updateStage = updateFailure(error)
        }
    }

    public func startUpdateCheck() {
        guard updateTask == nil, !updateStage.isBusy else { return }
        updateTask = Task { [weak self] in
            guard let self else { return }
            await self.checkForUpdates()
            self.updateTask = nil
        }
    }

    public func startUpdateInstall() {
        guard updateTask == nil, !updateStage.isBusy else { return }
        updateTask = Task { [weak self] in
            guard let self else { return }
            await self.installUpdate()
            self.updateTask = nil
        }
    }

    public func cancelUpdate() {
        guard updateStage.isBusy else { return }
        updateTask?.cancel()
        updateStage = .cancelling
    }

    public func restartAfterUpdate() async {
        guard updateStage == .restartRequired else { return }
        updateStage = .restarting
        do {
            try await HomebrewUpdateService(runner: runner).launchUpdatedApplication(
                home: FileManager.default.homeDirectoryForCurrentUser.path
            )
            #if canImport(AppKit)
            NSApplication.shared.terminate(nil)
            #else
            updateStage = .restartRequired
            #endif
        } catch {
            updateStage = updateFailure(error)
        }
    }

    private func updateFailure(_ error: Error) -> AppUpdateStage {
        if let updateError = error as? HomebrewUpdateError,
           case let .commandFailed(operation, message) = updateError {
            return .failed(operation: operation, message: message)
        }
        return .failed(operation: nil, message: error.localizedDescription)
    }

    // MARK: - Collection + analysis

    public func refresh(trigger: RefreshTrigger = .manual) async {
        guard !isRefreshing else { return }
        guard let ghPath, let status, status.ghAuthenticated, let login = status.ghLogin else {
            lastError = "gh is not ready. Open Settings to check dependencies."
            if trigger == .scheduled {
                recordScheduledRun(outcome: .failure, message: lastError)
            }
            return
        }
        isRefreshing = true
        lastError = nil
        defer { isRefreshing = false; lastRun = Date() }

        let github = GitHubService(runner: runner, ghPath: ghPath)
        let previousIDs = Set(items.map(\.id))
        do {
            let fetch = try await github.fetchAwaitingReviewResult(
                settings: settings,
                login: login
            )
            let prs = fetch.pullRequests
            // Fetch only — do NOT auto-analyze. Preserve any existing analysis for PRs
            // that are still open so a manual review isn't discarded on refresh.
            let previous = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            items = prs.map { pr in previous[pr.id] ?? PRItem(pr: pr) }
            lastRefreshDiagnostic = RefreshDiagnostic(
                date: Date(),
                outcome: .success,
                itemCount: prs.count,
                retryCount: fetch.retryCount,
                reachedSearchLimit: fetch.reachedSearchLimit,
                rateLimited: false,
                message: nil
            )
        } catch {
            lastError = "\(error)"
            let githubError = error as? GitHubError
            lastRefreshDiagnostic = RefreshDiagnostic(
                date: Date(),
                outcome: .failed,
                itemCount: items.count,
                retryCount: max(0, (githubError?.attempts ?? 1) - 1),
                reachedSearchLimit: false,
                rateLimited: githubError?.isRateLimited ?? false,
                message: "\(error)"
            )
            if trigger == .scheduled {
                recordScheduledRun(outcome: .failure, message: "\(error)")
            }
            return
        }

        let newOnes = items.filter { !previousIDs.contains($0.id) }
        if settings.notificationsEnabled, !newOnes.isEmpty {
            Notifier.notify(
                title: "PR Review Reminder",
                body: "\(newOnes.count) pull request(s) awaiting your review."
            )
        }

        // Token-free restore: if a stored review matches the PR's current head
        // commit, reuse it instead of spending tokens again. (`github` from above.)
        if settings.historyEnabled {
            let unrestored = items.filter { $0.analysis == nil }.map(\.pr)
            let headShas = await github.fetchHeadShas(unrestored)
            for item in items where item.analysis == nil {
                guard let sha = headShas[item.id],
                      let rec = history.record(repository: item.pr.repository, number: item.pr.number, headSha: sha),
                      let i = items.firstIndex(where: { $0.id == item.id }) else { continue }
                items[i].details = rec.details
                items[i].detailsState = .loaded
                items[i].analysis = rec.analysis
                items[i].usage = rec.usage
                items[i].state = .done
            }
        }

        // Optional: automatically review when enabled in settings.
        if settings.autoReview {
            for item in items where item.analysis == nil {
                await review(item.id, notifyOnComplete: false)
            }
        }
        if trigger == .scheduled {
            recordScheduledRun(outcome: .success)
        }
    }

    /// Fetches PR details (diff/body) without running AI, so the diff can be shown
    /// before a review is requested.
    public func ensureDetails(_ itemID: String) async {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        guard items[index].details == nil else {
            items[index].detailsState = .loaded
            return
        }
        guard items[index].detailsState != .loading else { return }
        guard let ghPath else {
            items[index].detailsState = .failed("gh is not ready.")
            return
        }
        let pr = items[index].pr
        items[index].detailsState = .loading
        let github = GitHubService(runner: runner, ghPath: ghPath)
        do {
            let details = try await github.fetchDetails(pr)
            if let i = items.firstIndex(where: { $0.id == itemID }) {
                items[i].details = details
                items[i].detailsState = .loaded
            }
        } catch {
            if let i = items.firstIndex(where: { $0.id == itemID }) {
                items[i].detailsState = .failed("\(error)")
            }
        }
    }

    /// Runs agent code review for a single PR on demand (fetch details + analyze).
    /// The `items` array may be replaced by a scheduled refresh during the long
    /// await, so the item is always re-located by id — never by a cached index.
    public func review(_ itemID: String, notifyOnComplete: Bool = true) async {
        guard let start = items.firstIndex(where: { $0.id == itemID }) else { return }
        guard let ghPath else { lastError = "gh is not ready."; return }
        if case .loading = items[start].state { return }

        func mutate(_ body: (inout PRItem) -> Void) {
            guard let i = items.firstIndex(where: { $0.id == itemID }) else { return }
            body(&items[i])
        }
        func current() -> PRItem? { items.first { $0.id == itemID } }

        mutate { $0.state = .loading }
        let github = GitHubService(runner: runner, ghPath: ghPath)
        let ai = AIService(runner: runner, claudePath: claudePath, codexPath: codexPath)
        guard let pr = current()?.pr else { return }
        do {
            let details: PRDetails
            if let existing = current()?.details {
                details = existing
            } else {
                details = try await github.fetchDetails(pr)
            }
            mutate {
                $0.details = details
                $0.detailsState = .loaded
            }
            if settings.historyEnabled, settings.reviewTokenBudget > 0 {
                let used = history.tokenTotal(windowDays: settings.reviewBudgetWindowDays)
                guard used < settings.reviewTokenBudget else {
                    throw AIError(String(
                        format: l("review_budget_exceeded"),
                        used.formatted(.number),
                        settings.reviewTokenBudget.formatted(.number),
                        settings.reviewBudgetWindowDays
                    ))
                }
            }
            let (analysis, usage) = try await ai.analyze(
                title: pr.title, body: details.body, diff: details.diff, settings: settings
            )
            mutate { $0.analysis = analysis; $0.usage = usage; $0.state = .done }
            // Persist to history for later viewing and token-free restore.
            let record = ReviewRecord(
                repository: pr.repository, number: pr.number, title: pr.title, author: pr.author,
                url: pr.url, headSha: details.headSha, tool: settings.aiTool, reviewedAt: Date(),
                analysis: analysis, usage: usage, details: details)
            if settings.historyEnabled {
                history.upsert(record)
                history.applyRetention(days: settings.historyRetentionDays)
                historyStorageDiagnostic = history.diagnostic
                historyItems = history.all()
            }
            if notifyOnComplete, settings.notificationsEnabled {
                let l = L10n(language: settings.appLanguage)
                Notifier.notify(title: l("review_done_title"),
                                body: String(format: l("review_done_body"), "\(pr.repository)#\(pr.number)"))
            }
        } catch is CancellationError {
            mutate { $0.state = .cancelled }
        } catch ProcessRunnerError.timedOut {
            mutate { $0.state = .timedOut }
        } catch {
            mutate { $0.state = .failed("\(error)") }
        }
    }

    /// Starts a user-visible review and retains its task so the user can cancel
    /// the underlying CLI process.
    public func startReview(_ itemID: String, notifyOnComplete: Bool = true) {
        guard reviewTasks[itemID] == nil else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.review(itemID, notifyOnComplete: notifyOnComplete)
            self.reviewTasks[itemID] = nil
        }
        reviewTasks[itemID] = task
    }

    public func cancelReview(_ itemID: String) {
        reviewTasks[itemID]?.cancel()
    }

    // MARK: - Publishing (explicit user actions only)

    public func postInlineComments(for item: PRItem, comments: [InlineComment]) async {
        guard let ghPath, let details = item.details else {
            lastError = "Missing PR details; refresh first."
            return
        }
        let github = GitHubService(runner: runner, ghPath: ghPath)
        do {
            try await github.requireCurrentHead(details.headSha, for: item.pr)
        } catch {
            lastError = "\(error)"
            return
        }
        lastError = nil
        do {
            try await github.postReview(
                comments: comments, on: item.pr, commitSha: details.headSha)
        } catch {
            lastError = "\(error)"
        }
    }

    /// Posts inline comments and then approves in one action.
    public func postInlineCommentsAndApprove(for item: PRItem, comments: [InlineComment], approveBody: String) async {
        guard let ghPath, let details = item.details else {
            lastError = "Missing PR details; refresh first."
            return
        }
        let github = GitHubService(runner: runner, ghPath: ghPath)
        do {
            try await github.requireCurrentHead(details.headSha, for: item.pr)
            try await github.postReview(
                comments: comments, on: item.pr, commitSha: details.headSha,
                approve: true, body: approveBody)
            items.removeAll { $0.id == item.id }
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

    public func postSummaryComment(for item: PRItem, override: String? = nil) async {
        guard let ghPath, let details = item.details else {
            lastError = "Missing PR details; refresh first."
            return
        }
        guard let summary = override ?? item.analysis?.summary else { return }
        let github = GitHubService(runner: runner, ghPath: ghPath)
        do {
            try await github.requireCurrentHead(details.headSha, for: item.pr)
            try await github.postSummaryComment(summary, on: item.pr)
        } catch {
            lastError = "\(error)"
        }
    }

    public func approve(_ item: PRItem, body: String?) async {
        guard let ghPath, let details = item.details else {
            lastError = "Missing PR details; refresh first."
            return
        }
        let github = GitHubService(runner: runner, ghPath: ghPath)
        do {
            try await github.requireCurrentHead(details.headSha, for: item.pr)
            try await github.approve(item.pr, body: body)
            items.removeAll { $0.id == item.id }
        } catch {
            lastError = "\(error)"
        }
    }

    // MARK: - Feedback (F5)

    private func makeAIService() -> AIService {
        AIService(runner: runner, claudePath: claudePath, codexPath: codexPath)
    }

    /// Tidy the feedback draft via the AI CLI. Returns nil on error (sets lastError).
    public func tidyFeedback(title: String, body: String) async -> (title: String, body: String)? {
        let feedback = FeedbackService(github: nil, ai: makeAIService())
        do {
            return try await feedback.tidy(title: title, body: body, settings: settings)
        } catch {
            lastError = "\(error)"
            return nil
        }
    }

    /// Submit feedback to this project's GitHub issue tracker.
    public func submitFeedback(title: String, body: String) async -> FeedbackService.SubmitResult? {
        let github = ghPath.map { GitHubService(runner: runner, ghPath: $0) }
        let feedback = FeedbackService(github: github, ai: makeAIService())
        do {
            return try await feedback.submit(title: title, body: body, ghPath: ghPath)
        } catch {
            lastError = "\(error)"
            return nil
        }
    }

    public func openInBrowser(_ item: PRItem) {
        #if canImport(AppKit)
        if let url = URL(string: item.pr.url) {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    // MARK: - Scheduling

    private func scheduleNextRun() {
        scheduleTimer?.invalidate()
        let next = Scheduler.nextRunDate(after: Date(), settings: settings)
        nextRun = next
        let interval = max(60, next.timeIntervalSinceNow)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                await self.refresh(trigger: .scheduled)
                self.scheduleNextRun()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        scheduleTimer = timer
    }

    private func recordScheduledRun(
        outcome: ScheduleRunRecord.Outcome,
        message: String? = nil
    ) {
        let record = ScheduleRunRecord(
            outcome: outcome,
            itemCount: items.count,
            message: message
        )
        scheduleRunStore.append(record)
        scheduleRuns = scheduleRunStore.all()
        if outcome == .failure, settings.notificationsEnabled {
            Notifier.notify(
                title: l("scheduled_refresh_failed"),
                body: message ?? l("scheduled_refresh_unknown_error")
            )
        }
    }
}
