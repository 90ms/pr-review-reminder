import SwiftUI

struct DiffView: View {
    @EnvironmentObject private var app: AppState
    let diff: String
    @State private var mode: Mode = .split

    enum Mode: String, CaseIterable, Identifiable { case split, unified; var id: String { rawValue } }

    private var rows: [DiffParser.Row] { DiffParser.parse(diff) }
    private var files: [DiffParser.FileSection] { DiffParser.fileSections(in: rows) }

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
                        fileNavigator(proxy: proxy)
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
                }
            }
        }
    }

    private var minimumContentWidth: CGFloat {
        mode == .split ? 1041 : 560
    }

    @ViewBuilder private func fileNavigator(proxy: ScrollViewProxy) -> some View {
        if !files.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(files) { file in
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
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
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
