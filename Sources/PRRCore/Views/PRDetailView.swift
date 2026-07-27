import SwiftUI

/// Large, resizable review view shown in a dedicated window.
public struct PRDetailView: View {
    @EnvironmentObject var app: AppState
    @State private var editableComments: [EditableComment] = []
    @State private var busy = false
    @State private var loadedFor: String?
    @State private var pending: PendingAction?
    @State private var previewInlineComments: [EditableComment] = []
    @State private var approveBody = ""
    @State private var layout: DetailLayout = .review
    @State private var diffTarget: DiffNavigationTarget?

    private struct EditableComment: Identifiable {
        let id: UUID
        var comment: InlineComment

        init(id: UUID = UUID(), comment: InlineComment) {
            self.id = id
            self.comment = comment
        }
    }

    private enum DetailLayout: String, CaseIterable, Identifiable {
        case review
        case changes
        case sideBySide

        var id: String { rawValue }
    }

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
            layoutPicker
            Divider()
            switch layout {
            case .review:
                analysisPane(item)
            case .changes:
                diffPane(item)
            case .sideBySide:
                HSplitView {
                    analysisPane(item)
                        .frame(minWidth: 320)
                    diffPane(item)
                        .frame(minWidth: 320)
                }
            }
        }
        .onAppear { syncComments(item); Task { await app.ensureDetails(item.id) } }
        .onChange(of: item.id) { syncComments(item); Task { await app.ensureDetails(item.id) } }
        .onChange(of: item.analysis) { syncComments(item) }
    }

    private var layoutPicker: some View {
        HStack {
            Picker(app.l("detail_layout"), selection: $layout) {
                Label(app.l("detail_review"), systemImage: "text.bubble")
                    .tag(DetailLayout.review)
                Label(app.l("detail_changes"), systemImage: "doc.text.magnifyingglass")
                    .tag(DetailLayout.changes)
                Label(app.l("detail_side_by_side"), systemImage: "rectangle.split.2x1")
                    .tag(DetailLayout.sideBySide)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 360)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func syncComments(_ item: PRItem) {
        if loadedFor != item.id {
            editableComments = makeEditableComments(item.analysis?.inlineComments ?? [])
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
                if let usage = item.usage,
                   case let label = usage.label(tokensUnit: app.l("tokens_unit")),
                   !label.isEmpty {
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
                Button { app.startReview(item.id) } label: {
                    Label(app.l("run_review"), systemImage: "sparkles")
                }.buttonStyle(.borderedProminent)
            }
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(app.l("analyzing")).foregroundStyle(.secondary)
                Spacer()
                Button(app.l("cancel_review")) { app.cancelReview(item.id) }
            }
        case .cancelled:
            retryStatus(message: app.l("review_cancelled"), item: item)
        case .timedOut:
            retryStatus(message: app.l("review_timed_out"), item: item)
        case .failed(let msg):
            HStack {
                Text("\(app.l("analysis_failed")): \(msg)").font(.caption).foregroundStyle(.red).lineLimit(2)
                Spacer()
                Button { app.startReview(item.id) } label: { Label(app.l("retry"), systemImage: "arrow.clockwise") }
            }
        case .done:
            HStack {
                Text(app.l("review_completed")).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button {
                    app.startReReview(item.id)
                } label: {
                    Label(app.l("review_again"), systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private func retryStatus(message: String, item: PRItem) -> some View {
        HStack {
            Text(message).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button { app.startReview(item.id) } label: {
                Label(app.l("retry"), systemImage: "arrow.clockwise")
            }
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
            ForEach(editableComments) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Button {
                            diffTarget = DiffNavigationTarget(
                                path: entry.comment.path,
                                line: entry.comment.line,
                                side: entry.comment.side
                            )
                            layout = .changes
                        } label: {
                            Text("\(entry.comment.path):\(entry.comment.line) · \(entry.comment.side)")
                                .font(.caption.monospaced())
                        }
                        .buttonStyle(.link)
                        Spacer()
                        Button(role: .destructive) {
                            editableComments.removeAll { $0.id == entry.id }
                        } label: {
                            Label(app.l("remove_inline_comment"), systemImage: "trash")
                        }
                        .labelStyle(.iconOnly)
                    }
                    TextEditor(text: editableBodyBinding(for: entry.id))
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
                    previewInlineComments = editableComments
                    pending = .inline(editableComments.map(\.comment))
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
            case .inline:
                Text(app.l("preview_inline")).font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if previewInlineComments.isEmpty {
                            Text(app.l("no_inline_comments_to_post"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(previewInlineComments) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text("\(entry.comment.path):\(entry.comment.line) · \(entry.comment.side)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button(role: .destructive) {
                                        previewInlineComments.removeAll { $0.id == entry.id }
                                    } label: {
                                        Label(app.l("remove_inline_comment"), systemImage: "trash")
                                    }
                                    .labelStyle(.iconOnly)
                                }
                                TextEditor(text: previewBodyBinding(for: entry.id))
                                .font(.callout)
                                .frame(minHeight: 64)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
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
                if case .inline = action {
                    Button {
                        Task {
                            busy = true
                            let commentsToPost = cleanedInlineComments(previewInlineComments)
                            await app.postInlineCommentsAndApprove(
                                for: item, comments: commentsToPost, approveBody: app.l("approve_after_comments_body"))
                            editableComments = makeEditableComments(commentsToPost)
                            busy = false
                            pending = nil
                        }
                    } label: { Label(app.l("post_and_approve"), systemImage: "checkmark.seal") }
                        .disabled(busy || cleanedInlineComments(previewInlineComments).isEmpty)
                }
                Button {
                    Task {
                        busy = true
                        switch action {
                        case .inline:
                            let commentsToPost = cleanedInlineComments(previewInlineComments)
                            await app.postInlineComments(for: item, comments: commentsToPost)
                            editableComments = makeEditableComments(commentsToPost)
                        case .summary(let text): await app.postSummaryComment(for: item, override: text)
                        case .approve: await app.approve(item, body: approveBody.isEmpty ? nil : approveBody)
                        }
                        busy = false
                        pending = nil
                    }
                } label: { Label(busy ? app.l("posting") : app.l("submit"), systemImage: "paperplane") }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || inlineSubmitDisabled(action))
            }
        }
        .padding(16)
        .frame(width: 520, height: 460)
    }

    private func makeEditableComments(_ comments: [InlineComment]) -> [EditableComment] {
        comments.map { EditableComment(comment: $0) }
    }

    private func editableBodyBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: {
                editableComments.first { $0.id == id }?.comment.body ?? ""
            },
            set: { value in
                guard let index = editableComments.firstIndex(where: { $0.id == id }) else {
                    return
                }
                editableComments[index].comment.body = value
            }
        )
    }

    private func previewBodyBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: {
                previewInlineComments.first { $0.id == id }?.comment.body ?? ""
            },
            set: { value in
                guard let index = previewInlineComments.firstIndex(where: { $0.id == id }) else {
                    return
                }
                previewInlineComments[index].comment.body = value
            }
        )
    }

    private func cleanedInlineComments(_ comments: [EditableComment]) -> [InlineComment] {
        comments.compactMap { entry in
            let comment = entry.comment
            let body = comment.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return InlineComment(path: comment.path, line: comment.line, side: comment.side, body: body)
        }
    }

    private func inlineSubmitDisabled(_ action: PendingAction) -> Bool {
        if case .inline = action {
            return cleanedInlineComments(previewInlineComments).isEmpty
        }
        return false
    }

    private func diffPane(_ item: PRItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(app.l("diff")).font(.headline).padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
            if let diff = item.details?.diff, !diff.isEmpty {
                if AIService.isDiffTruncated(diff) {
                    Label(app.l("diff_truncated_warning"), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                }
                DiffView(diff: diff, target: diffTarget)
            } else if item.details != nil {
                detailPlaceholder(
                    systemImage: "doc.text.magnifyingglass",
                    message: app.l("diff_empty")
                )
            } else {
                switch item.detailsState {
                case .failed(let message):
                    detailError(message: message, itemID: item.id)
                case .idle, .loading:
                    Spacer()
                    HStack(spacing: 8) {
                        Spacer()
                        ProgressView().controlSize(.small)
                        Text(app.l("loading_diff")).foregroundStyle(.secondary)
                        Spacer()
                    }
                    Spacer()
                case .loaded:
                    detailPlaceholder(
                        systemImage: "doc.text.magnifyingglass",
                        message: app.l("diff_empty")
                    )
                }
            }
        }
    }

    private func detailError(message: String, itemID: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.orange)
            Text(app.l("diff_load_failed")).font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Button {
                Task { await app.ensureDetails(itemID) }
            } label: {
                Label(app.l("retry"), systemImage: "arrow.clockwise")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func detailPlaceholder(systemImage: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.title2).foregroundStyle(.secondary)
            Text(message).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }
}
