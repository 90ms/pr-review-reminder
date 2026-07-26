import SwiftUI

/// Compact card shown in the menu-bar popover list. Full review happens in the
/// detail window (opened via "Details").
struct PRCardView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    let item: PRItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            switch item.state {
            case .idle:
                Text(app.l("not_reviewed")).font(.caption).foregroundStyle(.secondary)
                idleButtons
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(app.l("analyzing")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(app.l("cancel_review")) {
                        app.cancelReview(item.id)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            case .cancelled:
                Text(app.l("review_cancelled")).font(.caption).foregroundStyle(.secondary)
                idleButtons
            case .timedOut:
                Text(app.l("review_timed_out")).font(.caption).foregroundStyle(.orange)
                idleButtons
            case .failed(let message):
                Text("\(app.l("analysis_failed")): \(message)").font(.caption).foregroundStyle(.red).lineLimit(2)
                idleButtons
            case .done:
                if let analysis = item.analysis {
                    Text(analysis.summary).font(.callout).lineLimit(3)
                    metaRow(analysis)
                }
                actionButtons
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(item.pr.repository).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text("#\(item.pr.number)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text(item.pr.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            Label(item.pr.author, systemImage: "person").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func metaRow(_ analysis: Analysis) -> some View {
        HStack(spacing: 10) {
            if !analysis.reviewPoints.isEmpty {
                Label("\(analysis.reviewPoints.count)", systemImage: "exclamationmark.bubble")
            }
            if !analysis.inlineComments.isEmpty {
                Label("\(analysis.inlineComments.count)", systemImage: "text.bubble")
            }
            if let usage = item.usage, let label = usageLabel(usage) {
                Label(label, systemImage: "circlebadge.2")
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    private func usageLabel(_ usage: AIUsage) -> String? {
        let text = usage.label(tokensUnit: app.l("tokens_unit"))
        return text.isEmpty ? nil : text
    }

    private var idleButtons: some View {
        HStack(spacing: 8) {
            Button {
                app.startReview(item.id)
            } label: { Label(item.state.isFailed ? app.l("retry") : app.l("run_review"), systemImage: "sparkles") }
            .buttonStyle(.borderedProminent).controlSize(.small)

            Button {
                app.select(item); openWindow(id: "pr-detail"); NSApplication.shared.activate(ignoringOtherApps: true)
            } label: { Label(app.l("view_detail"), systemImage: "rectangle.expand.vertical") }
            .buttonStyle(.bordered).controlSize(.small)

            Spacer()
            Button { app.openInBrowser(item) } label: { Image(systemName: "arrow.up.forward.square") }
                .buttonStyle(.borderless).help(app.l("open_github"))
                .accessibilityLabel(app.l("open_github"))
        }
        .font(.caption)
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button {
                app.startReReview(item.id)
            } label: { Label(app.l("review_again"), systemImage: "arrow.clockwise") }
            .buttonStyle(.bordered).controlSize(.small)

            Button {
                app.select(item)
                openWindow(id: "pr-detail"); NSApplication.shared.activate(ignoringOtherApps: true)
            } label: { Label(app.l("view_detail"), systemImage: "rectangle.expand.vertical") }
            .buttonStyle(.borderedProminent).controlSize(.small)

            Spacer()
            Button { app.openInBrowser(item) } label: { Image(systemName: "arrow.up.forward.square") }
                .buttonStyle(.borderless).help(app.l("open_github"))
                .accessibilityLabel(app.l("open_github"))
        }
        .font(.caption)
    }
}
