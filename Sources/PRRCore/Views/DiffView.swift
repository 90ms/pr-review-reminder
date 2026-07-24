import SwiftUI

struct DiffNavigationTarget: Equatable {
    let id = UUID()
    let path: String
    let line: Int
    let side: String
}

struct DiffView: View {
    @EnvironmentObject private var app: AppState
    let target: DiffNavigationTarget?
    private let rows: [DiffParser.Row]
    private let files: [DiffParser.FileSection]
    @State private var mode: Mode = .split
    @State private var fileQuery = ""
    @State private var changeIndex = -1

    enum Mode: String, CaseIterable, Identifiable { case split, unified; var id: String { rawValue } }

    init(diff: String, target: DiffNavigationTarget? = nil) {
        self.target = target
        let parsed = DiffParser.parse(diff)
        self.rows = parsed
        self.files = DiffParser.fileSections(in: parsed)
    }

    private var filteredFiles: [DiffParser.FileSection] {
        guard !fileQuery.isEmpty else { return files }
        return files.filter { $0.path.localizedCaseInsensitiveContains(fileQuery) }
    }

    private var changeRowIDs: [Int] {
        rows.filter { $0.kind == .line && $0.isChange }.map(\.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $mode) {
                    Text(app.l("diff_split")).tag(Mode.split)
                    Text(app.l("diff_unified")).tag(Mode.unified)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                Spacer()
            }
            .padding(8)
            Divider()
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                        navigationBar(proxy: proxy)
                        Divider()
                        ScrollView([.horizontal, .vertical]) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(rows) { row in
                                    rowView(row)
                                        .id(row.id)
                                }
                            }
                            .frame(
                                minWidth: max(viewport.size.width, minimumContentWidth),
                                alignment: .topLeading
                            )
                        }
                        .defaultScrollAnchor(.topLeading)
                    }
                    .task(id: target?.id) {
                        navigate(to: target, proxy: proxy)
                    }
                }
            }
        }
    }

    private var minimumContentWidth: CGFloat {
        mode == .split ? 1041 : 560
    }

    @ViewBuilder private func navigationBar(proxy: ScrollViewProxy) -> some View {
        if !files.isEmpty {
            VStack(spacing: 4) {
                HStack {
                    TextField(app.l("filter_files"), text: $fileQuery)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                    Spacer()
                    Button {
                        moveChange(by: -1, proxy: proxy)
                    } label: {
                        Label(app.l("previous_change"), systemImage: "chevron.up")
                    }
                    .disabled(changeRowIDs.isEmpty)
                    Button {
                        moveChange(by: 1, proxy: proxy)
                    } label: {
                        Label(app.l("next_change"), systemImage: "chevron.down")
                    }
                    .disabled(changeRowIDs.isEmpty)
                }
                .labelStyle(.iconOnly)
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(filteredFiles) { file in
                            Button {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(file.id, anchor: .topLeading)
                                }
                            } label: {
                                Label(file.path, systemImage: "doc.text")
                                    .lineLimit(1)
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .help(file.path)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func moveChange(by offset: Int, proxy: ScrollViewProxy) {
        guard !changeRowIDs.isEmpty else { return }
        changeIndex = (changeIndex + offset + changeRowIDs.count) % changeRowIDs.count
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(changeRowIDs[changeIndex], anchor: .center)
        }
    }

    private func navigate(to target: DiffNavigationTarget?, proxy: ScrollViewProxy) {
        guard let target,
              let rowID = DiffParser.targetRowID(
                in: rows,
                path: target.path,
                line: target.line,
                side: target.side
              ) else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(rowID, anchor: .center)
        }
    }

    @ViewBuilder private func rowView(_ row: DiffParser.Row) -> some View {
        switch row.kind {
        case .fileHeader:
            Text(row.header ?? "")
                .font(.caption.monospaced().weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.18))
        case .hunkHeader:
            Text(row.header ?? "")
                .font(.caption2.monospaced())
                .foregroundStyle(.teal)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.teal.opacity(0.08))
        case .line:
            if mode == .split {
                HStack(spacing: 0) {
                    cell(row.left, isChange: row.isChange, side: .left)
                    Divider()
                    cell(row.right, isChange: row.isChange, side: .right)
                }
                .frame(minWidth: minimumContentWidth, alignment: .leading)
            } else {
                unifiedLine(row)
            }
        }
    }

    private enum Side { case left, right }

    @ViewBuilder private func cell(_ cell: DiffParser.Cell?, isChange: Bool, side: Side) -> some View {
        let bg: Color = {
            guard isChange, cell != nil else { return .clear }
            return side == .left ? Color.red.opacity(0.14) : Color.green.opacity(0.14)
        }()
        HStack(alignment: .top, spacing: 6) {
            Text(cell?.number.map(String.init) ?? "")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
            Text(cell?.text ?? "")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 6).padding(.vertical, 1)
        .frame(minWidth: 520, alignment: .leading)
        .background(bg)
    }

    @ViewBuilder private func unifiedLine(_ row: DiffParser.Row) -> some View {
        if row.isChange {
            if let l = row.left {
                unifiedText(prefix: "-", num: l.number, text: l.text, color: .red)
            }
            if let r = row.right {
                unifiedText(prefix: "+", num: r.number, text: r.text, color: .green)
            }
        } else if let c = row.left {
            unifiedText(prefix: " ", num: c.number, text: c.text, color: nil)
        }
    }

    private func unifiedText(prefix: String, num: Int?, text: String, color: Color?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(num.map(String.init) ?? "").font(.caption2.monospaced()).foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
            Text("\(prefix) \(text)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color ?? .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 6).padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color?.opacity(0.12) ?? .clear)
    }
}
