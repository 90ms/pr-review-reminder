import SwiftUI

/// Large, resizable review view shown in a dedicated window.
public struct PRDetailView: View {
    @EnvironmentObject var app: AppState
    @State private var editableComments: [InlineComment] = []
    @State private var busy = false
    @State private var loadedFor: String?
    @State private var pending: PendingAction?
    @State private var approveBody = ""

    enum PendingAction: Identifiable {
        case inline([InlineComment])
        case summary(String)
        case approve
        var id: String {
            switch self {
            case .inline: return "inline"
            case .summary: return "summary"
            case .approve: return "approve"
            }
        }
    }

    public init() {}

    public var body: some View {
        Group {
            if let item = app.selectedItem {
                content(item)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .sheet(item: $pending) { action in
            if let item = app.selectedItem { confirmSheet(item, action) }
        }
    }

    private func content(_ item: PRItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(item)
            Divider()
            HSplitView {
                analysisPane(item)
                    .frame(minWidth: 320)
                diffPane(item)
                    .frame(minWidth: 320)
            }
        }
        .onAppear { syncComments(item); Task { await app.ensureDetails(item.id) } }
        .onChange(of: item.id) { syncComments(item); Task { await app.ensureDetails(item.id) } }
        .onChange(of: item.analysis) { syncComments(item) }
    }

    private func syncComments(_ item: PRItem) {
        if loadedFor != item.id {
            editableComments = item.analysis?.inlineComments ?? []
            loadedFor = item.id
        }
    }

    private func header(_ item: PRItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.pr.repository).foregroundStyle(.secondary)
                Text("#\(item.pr.number)").font(.body.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Text(item.pr.changeStat).font(.callout.monospaced()).foregroundStyle(.secondary)
                Button { app.openInBrowser(item) } label: { Label(app.l("open_github"), systemImage: "arrow.up.forward.square") }
            }
            Text(item.pr.title).font(.title3.weight(.semibold))
            HStack(spacing: 12) {
                Label(item.pr.author, systemImage: "person")
                if let usage = item.usage, case let label = usage.label(), !label.isEmpty {
                    Label(label, systemImage: "circlebadge.2")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
    }

    @ViewBuilder private func reviewStatusBar(_ item: PRItem) -> some View {
        switch item.state {
        case .idle:
            HStack {
                Text(app.l("not_reviewed")).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await app.review(item.id) } } label: {
                    Label(app.l("run_review"), systemImage: "sparkles")
                }.buttonStyle(.borderedProminent)
            }
        case .loading:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(app.l("analyzing")).foregroundStyle(.secondary) }
        case .failed(let msg):
            HStack {
                Text("\(app.l("analysis_failed")): \(msg)").font(.caption).foregroundStyle(.red).lineLimit(2)
                Spacer()
                Button { Task { await app.review(item.id) } } label: { Label(app.l("retry"), systemImage: "arrow.clockwise") }
            }
        case .done:
            EmptyView()
        }
    }

    private func analysisPane(_ item: PRItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                reviewStatusBar(item)
                if let analysis = item.analysis {
                    section(app.l("summary")) { Text(analysis.summary).font(.callout).textSelection(.enabled) }

                    if !analysis.reviewPoints.isEmpty {
                        section(app.l("review_points")) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(analysis.reviewPoints) { p in
                                    HStack(alignment: .top, spacing: 8) {
                                        SeverityDot(severity: p.severity).padding(.top, 5)
                                        Text(p.text).font(.callout).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }

                    if !editableComments.isEmpty {
                        section("\(app.l("inline_comments")) (\(editableComments.count))") {
                            inlineEditor
                        }
                        actionButtons(item)
                    }
                }
            }
            .padding(12)
        }
    }

    private var inlineEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(editableComments.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(editableComments[i].path):\(editableComments[i].line) · \(editableComments[i].side)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    TextEditor(text: Binding(
                        get: { editableComments[i].body },
                        set: { editableComments[i].body = $0 }
                    ))
                    .font(.callout)
                    .frame(minHeight: 60)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                }
            }
        }
    }

    private func actionButtons(_ item: PRItem) -> some View {
        HStack(spacing: 10) {
            if !editableComments.isEmpty {
                Button {
                    pending = .inline(editableComments)
                } label: { Label(app.l("post_comments"), systemImage: "text.bubble") }
                    .buttonStyle(.borderedProminent)
            }
            Button {
                pending = .summary(item.analysis?.summary ?? "")
            } label: { Label(app.l("summary"), systemImage: "square.and.pencil") }
            Button {
                approveBody = ""
                pending = .approve
            } label: { Label(app.l("approve"), systemImage: "checkmark.seal") }
        }
    }

    // MARK: - Preview & confirm before any submission

    @ViewBuilder private func confirmSheet(_ item: PRItem, _ action: PendingAction) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(item.pr.repository).foregroundStyle(.secondary)
                Text("#\(item.pr.number)").font(.body.monospaced()).foregroundStyle(.secondary)
            }
            Divider()

            switch action {
            case .inline(let comments):
                Text(app.l("preview_inline")).font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(comments) { c in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(c.path):\(c.line) · \(c.side)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(c.body).font(.callout).textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        }
                    }
                }
            case .summary(let text):
                Text(app.l("preview_summary")).font(.headline)
                ScrollView { Text(text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            case .approve:
                Text(app.l("preview_approve")).font(.headline)
                let highCount = item.analysis?.reviewPoints.filter { $0.severity == .high }.count ?? 0
                if highCount > 0 {
                    Text(String(format: app.l("caution_high"), highCount)).font(.callout).foregroundStyle(.orange)
                } else {
                    Text(app.l("no_high")).font(.callout).foregroundStyle(.secondary)
                }
                TextField(app.l("approve_body_ph"), text: $approveBody).textFieldStyle(.roundedBorder)
            }

            Spacer()
            HStack {
                Button(app.l("cancel")) { pending = nil }
                Spacer()
                if case .inline(let comments) = action {
                    Button {
                        Task {
                            busy = true
                            await app.postInlineCommentsAndApprove(
                                for: item, comments: comments, approveBody: app.l("approve_after_comments_body"))
                            busy = false
                            pending = nil
                        }
                    } label: { Label(app.l("post_and_approve"), systemImage: "checkmark.seal") }
                        .disabled(busy)
                }
                Button {
                    Task {
                        busy = true
                        switch action {
                        case .inline(let comments): await app.postInlineComments(for: item, comments: comments)
                        case .summary(let text): await app.postSummaryComment(for: item, override: text)
                        case .approve: await app.approve(item, body: approveBody.isEmpty ? nil : approveBody)
                        }
                        busy = false
                        pending = nil
                    }
                } label: { Label(busy ? app.l("posting") : app.l("submit"), systemImage: "paperplane") }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
            }
        }
        .padding(16)
        .frame(width: 520, height: 460)
    }

    private func diffPane(_ item: PRItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(app.l("diff")).font(.headline).padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
            if let diff = item.details?.diff, !diff.isEmpty {
                DiffView(diff: diff)
            } else {
                Spacer()
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                Spacer()
            }
        }
    }

    @ViewBuilder private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }
}
