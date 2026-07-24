import SwiftUI

public struct HistoryView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingDeleteAll = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            totalsHeader
            Divider()
            if app.historyItems.isEmpty {
                Spacer()
                Text(app.l("history_empty")).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(app.historyItems) { rec in
                        recordRow(rec)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .toolbar {
            if !app.historyItems.isEmpty {
                Button(role: .destructive) {
                    confirmingDeleteAll = true
                } label: {
                    Label(app.l("delete_all_history"), systemImage: "trash")
                }
            }
        }
        .confirmationDialog(
            app.l("delete_all_history_confirm"),
            isPresented: $confirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button(app.l("delete_all_history"), role: .destructive) {
                app.deleteAllHistory()
            }
            Button(app.l("cancel"), role: .cancel) {}
        }
    }

    private var totalsHeader: some View {
        let totals = app.historyTotals()
        return HStack(spacing: 20) {
            VStack(alignment: .leading) {
                Text(app.l("total_usage")).font(.caption).foregroundStyle(.secondary)
                Text("\(totals.tokens.formatted(.number)) \(app.l("tokens_unit"))").font(.title3.weight(.semibold))
            }
            VStack(alignment: .leading) {
                Text(app.l("cost")).font(.caption).foregroundStyle(.secondary)
                Text(String(format: "$%.4f", totals.costUSD)).font(.title3.weight(.semibold))
            }
            VStack(alignment: .leading) {
                Text(app.l("history")).font(.caption).foregroundStyle(.secondary)
                Text(String(format: app.l("reviews_count"), totals.count)).font(.title3.weight(.semibold))
            }
            Spacer()
        }
        .padding(14)
    }

    private func recordRow(_ rec: ReviewRecord) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(rec.analysis.summary).font(.callout).textSelection(.enabled)
                ForEach(rec.analysis.reviewPoints) { p in
                    HStack(alignment: .top, spacing: 6) {
                        SeverityDot(severity: p.severity).padding(.top, 4)
                        Text(p.text).font(.caption)
                    }
                }
                if !rec.analysis.inlineComments.isEmpty {
                    Text("\(app.l("inline_comments")): \(rec.analysis.inlineComments.count)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rec.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    HStack(spacing: 8) {
                        Text("\(rec.repository)#\(rec.number)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                        Text(rec.tool.displayName).font(.caption2).foregroundStyle(.secondary)
                        Text(rec.reviewedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let usage = rec.usage,
                   case let label = usage.label(tokensUnit: app.l("tokens_unit")),
                   !label.isEmpty {
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                }
                Button {
                    if let url = URL(string: rec.url) { NSWorkspace.shared.open(url) }
                } label: { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(.borderless)
                    .help(app.l("open_github"))
                Button {
                    app.selectHistory(rec)
                    openWindow(id: "history-detail")
                } label: { Image(systemName: "doc.text.magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help(app.l("view_detail"))
                Button(role: .destructive) { app.deleteHistory(id: rec.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
        }
    }
}
