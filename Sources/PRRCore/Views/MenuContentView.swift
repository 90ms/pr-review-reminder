import SwiftUI

public struct MenuContentView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingQuit = false
    @State private var selectedInbox: Inbox = .reviewRequests

    private let maxListHeight: CGFloat = 620
    /// Above this many PRs, switch to a capped scroll area; at or below, the popover
    /// sizes exactly to content so there is no scroll bar.
    private let scrollThreshold = 4

    public init() {}

    private enum Inbox: String, CaseIterable, Identifiable {
        case reviewRequests
        case authoredFeedback

        var id: String { rawValue }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 460)
        .confirmationDialog(
            app.l("quit_while_busy"),
            isPresented: $confirmingQuit,
            titleVisibility: .visible
        ) {
            Button(app.l("quit_anyway"), role: .destructive) {
                NSApplication.shared.terminate(nil)
            }
            Button(app.l("cancel"), role: .cancel) {}
        } message: {
            Text(app.l("quit_while_busy_help"))
        }
        .alert(
            app.l("unexpected_termination_title"),
            isPresented: Binding(
                get: { app.pendingTerminationReport != nil },
                set: { if !$0 { app.dismissTerminationReport() } }
            )
        ) {
            Button(app.l("report_issue")) {
                app.prepareTerminationFeedback()
                openWindow(id: "feedback")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            Button(app.l("dismiss"), role: .cancel) {
                app.dismissTerminationReport()
            }
        } message: {
            Text(app.l("unexpected_termination_message"))
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "checklist")
            Text("PR Review Reminder").font(.headline)
            Spacer()
            if app.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await app.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help(app.l("refresh"))
                    .accessibilityLabel(app.l("refresh"))
            }
        }
        .padding(10)
    }

    @ViewBuilder private var content: some View {
        if let status = app.status, !status.isUsable {
            unavailableView(status)
        } else if app.items.isEmpty && app.feedbackItems.isEmpty {
            emptyView
        } else if visibleCount <= scrollThreshold {
            VStack(spacing: 0) {
                inboxPicker
                selectedCardStack
            }
        } else {
            VStack(spacing: 0) {
                inboxPicker
                ScrollView { selectedCardStack }
                    .frame(height: maxListHeight)
            }
        }
    }

    private var visibleCount: Int {
        switch selectedInbox {
        case .reviewRequests: return app.items.count
        case .authoredFeedback: return app.feedbackItems.count
        }
    }

    private var inboxPicker: some View {
        Picker("", selection: $selectedInbox) {
            Text("\(app.l("inbox_review_requests")) \(app.items.count)").tag(Inbox.reviewRequests)
            Text("\(app.l("inbox_my_feedback")) \(app.feedbackItems.count)").tag(Inbox.authoredFeedback)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding([.horizontal, .top], 10)
    }

    @ViewBuilder private var selectedCardStack: some View {
        switch selectedInbox {
        case .reviewRequests:
            if app.items.isEmpty {
                inboxEmptyView(app.l("nothing_awaiting"))
            } else {
                cardStack
            }
        case .authoredFeedback:
            if app.feedbackItems.isEmpty {
                VStack(spacing: 0) {
                    inboxEmptyView(app.l("nothing_feedback"))
                    if let error = app.feedbackError {
                        Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding([.horizontal, .bottom], 10)
                    }
                }
            } else {
                feedbackCardStack
            }
        }
    }

    private var cardStack: some View {
        VStack(spacing: 8) {
            ForEach(app.items) { item in
                PRCardView(item: item)
            }
        }
        .padding(10)
    }

    private var feedbackCardStack: some View {
        VStack(spacing: 8) {
            ForEach(app.feedbackItems) { item in
                PRFeedbackCardView(item: item)
            }
            if let error = app.feedbackError {
                Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
    }

    private func inboxEmptyView(_ message: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.secondary)
            Text(message).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private func unavailableView(_ status: DependencyStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(app.l("setup_needed")).font(.subheadline.weight(.semibold))
            ForEach(status.problems, id: \.self) { Text("• \($0)").font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var emptyView: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.secondary)
            Text(app.lastRun == nil ? app.l("no_data") : app.l("nothing_awaiting"))
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private var footer: some View {
        HStack {
            if let error = app.lastError {
                Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    if let last = app.lastRun {
                        Text("\(app.l("updated")) \(last.formatted(date: .omitted, time: .shortened))")
                    }
                    if let next = app.nextRun {
                        Text("\(app.l("next_run")) \(next.formatted(date: .omitted, time: .shortened))")
                    }
                    if let diagnostic = app.lastRefreshDiagnostic {
                        if diagnostic.reachedSearchLimit {
                            Text(app.l("search_limit_warning")).foregroundStyle(.orange)
                        } else if diagnostic.retryCount > 0 {
                            Text(String(
                                format: app.l("github_retried"),
                                diagnostic.retryCount
                            ))
                        }
                    }
                    if let feedbackError = app.feedbackError {
                        Text(feedbackError).foregroundStyle(.red).lineLimit(2)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(app.l("history")) {
                openWindow(id: "history")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }.buttonStyle(.borderless).font(.caption)
            Button(app.l("feedback")) {
                openWindow(id: "feedback")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }.buttonStyle(.borderless).font(.caption)
            Button(app.l("settings")) {
                openWindow(id: "settings")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }.buttonStyle(.borderless).font(.caption)
            Button(app.l("quit")) {
                if app.hasActiveOperations {
                    confirmingQuit = true
                } else {
                    NSApplication.shared.terminate(nil)
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(10)
    }
}
