import SwiftUI

public struct FeedbackView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var body_ = ""
    @State private var preview: String?
    @State private var createdURL: String?
    @State private var busy = false
    @State private var refreshingHistory = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(app.l("feedback")).font(.title3.weight(.semibold))

            TextField(app.l("fb_title"), text: $title)
                .textFieldStyle(.roundedBorder)

            Text(app.l("fb_body")).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $body_)
                .font(.callout)
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))

            if let preview {
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.l("fb_hold")).font(.caption).foregroundStyle(.orange)
                    Text(app.l("fb_preview")).font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                        Text(preview).font(.caption.monospaced()).textSelection(.enabled).padding(8)
                    }
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                    .frame(maxHeight: 90)
                }
            }
            if let createdURL {
                Text(createdURL).font(.caption.monospaced()).foregroundStyle(.green).textSelection(.enabled)
            }

            Divider()

            HStack {
                Text(app.l("fb_history")).font(.headline)
                Spacer()
                Button {
                    Task {
                        refreshingHistory = true
                        await app.refreshFeedbackHistory()
                        refreshingHistory = false
                    }
                } label: {
                    Label(app.l("fb_refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(refreshingHistory || app.feedbackRecords.isEmpty)
            }

            if app.feedbackRecords.isEmpty {
                Text(app.l("fb_history_empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                List(app.feedbackRecords) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("#\(record.number) \(record.title)")
                                .lineLimit(1)
                            Spacer()
                            Text(statusText(record))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(statusColor(record.state))
                        }
                        if let url = URL(string: record.url) {
                            Link(record.url, destination: url)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                        } else {
                            Text(record.url)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .frame(minHeight: 100)
            }

            HStack {
                Button {
                    Task {
                        busy = true
                        if let tidied = await app.tidyFeedback(title: title, body: body_) {
                            title = tidied.title; body_ = tidied.body
                        }
                        busy = false
                    }
                } label: { Label(busy ? app.l("fb_tidying") : app.l("fb_tidy"), systemImage: "wand.and.stars") }
                .disabled(busy || (title.isEmpty && body_.isEmpty))

                Spacer()
                Button(app.l("fb_cancel")) { dismiss() }
                Button {
                    Task {
                        busy = true
                        let result = await app.submitFeedback(title: title, body: body_)
                        switch result {
                        case .held(let p): preview = p; createdURL = nil
                        case .created(let out, _):
                            createdURL = out
                            preview = nil
                            title = ""
                            body_ = ""
                            dismiss()
                        case .none: break
                        }
                        busy = false
                    }
                } label: { Label(app.l("fb_submit"), systemImage: "paperplane") }
                .buttonStyle(.borderedProminent)
                .disabled(busy || title.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520, height: 560)
        .onChange(of: app.feedbackDraft?.id, initial: true) {
            guard let draft = app.feedbackDraft else { return }
            title = draft.title
            body_ = draft.body
            app.clearFeedbackDraft(id: draft.id)
        }
    }

    private func statusText(_ record: FeedbackRecord) -> String {
        if record.state == .closed, record.stateReason?.lowercased() == "completed" {
            return app.l("fb_resolved")
        }
        switch record.state {
        case .open:
            return app.l("fb_open")
        case .closed:
            return app.l("fb_closed")
        case .unknown:
            return app.l("fb_unknown")
        }
    }

    private func statusColor(_ state: FeedbackIssueState) -> Color {
        switch state {
        case .open:
            return .blue
        case .closed:
            return .green
        case .unknown:
            return .secondary
        }
    }
}
