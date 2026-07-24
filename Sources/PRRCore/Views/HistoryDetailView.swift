import SwiftUI

/// Read-only detail for a persisted review. Publishing remains available only
/// from the live PR detail after a fresh review has fetched the current head.
public struct HistoryDetailView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var preparingReview = false

    public init() {}

    public var body: some View {
        Group {
            if let record = app.selectedHistoryRecord {
                content(record)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
    }

    private func content(_ record: ReviewRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(record)
            Divider()
            HSplitView {
                analysis(record)
                    .frame(minWidth: 320)
                VStack(alignment: .leading, spacing: 0) {
                    Text(app.l("diff"))
                        .font(.headline)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                    DiffView(diff: record.details.diff)
                }
                .frame(minWidth: 320)
            }
        }
    }

    private func header(_ record: ReviewRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(record.repository).foregroundStyle(.secondary)
                Text("#\(record.number)").font(.body.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button {
                    if let url = URL(string: record.url) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label(app.l("open_github"), systemImage: "arrow.up.forward.square")
                }
                Button {
                    preparingReview = true
                    Task {
                        if let itemID = await app.prepareReReview(from: record) {
                            openWindow(id: "pr-detail")
                            await app.review(itemID)
                        }
                        preparingReview = false
                    }
                } label: {
                    Label(app.l("review_again"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(preparingReview)
            }
            Text(record.title).font(.title3.weight(.semibold))
            HStack(spacing: 10) {
                Label(record.author, systemImage: "person")
                Text(record.reviewedAt.formatted(date: .abbreviated, time: .shortened))
                Text(record.headSha.prefix(8)).font(.caption.monospaced())
                if let usage = record.usage, case let label = usage.label(), !label.isEmpty {
                    Text(label)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private func analysis(_ record: ReviewRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section(app.l("summary")) {
                    Text(record.analysis.summary).font(.callout).textSelection(.enabled)
                }
                if !record.analysis.reviewPoints.isEmpty {
                    section(app.l("review_points")) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(record.analysis.reviewPoints) { point in
                                HStack(alignment: .top, spacing: 8) {
                                    SeverityDot(severity: point.severity).padding(.top, 5)
                                    Text(point.text).font(.callout).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                if !record.analysis.inlineComments.isEmpty {
                    section("\(app.l("inline_comments")) (\(record.analysis.inlineComments.count))") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(record.analysis.inlineComments) { comment in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(comment.path):\(comment.line) · \(comment.side)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                    Text(comment.body).font(.callout).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
