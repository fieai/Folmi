import SwiftUI

struct QuickOpenSheet: View {
    let paths: [String]
    let onOpen: (QuickOpenMatch) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    private var matches: [QuickOpenMatch] { QuickOpenMatcher.matches(paths: paths, query: query) }

    var body: some View {
        let matches = self.matches
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("按名称或路径查找，支持 文件:行:列", text: $query)
                    .textFieldStyle(.plain).themedFont(.system(size: 15), points: 15)
                    .focused($searchFocused).onSubmit(openSelected)
                    .accessibilityLabel("快速打开文件").accessibilityIdentifier("quick-open-query")
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if matches.isEmpty {
                            ContentUnavailableView("没有匹配文件", systemImage: "doc.text.magnifyingglass",
                                                   description: Text("换一个文件名或路径试试。"))
                                .frame(maxWidth: .infinity).padding(.top, 30)
                        }
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                            Button { open(match) } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 5) {
                                            Text((match.path as NSString).lastPathComponent).themedFont(.system(size: 13, weight: .medium), points: 13)
                                            if let line = match.line {
                                                Text(":\(line)" + (match.column.map { ":\($0)" } ?? ""))
                                                    .themedFont(.system(size: 11, design: .monospaced), points: 11).foregroundStyle(.secondary)
                                            }
                                        }.lineLimit(1)
                                        Text(match.path).themedFont(.system(size: 11), points: 11).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer(minLength: 5)
                                    if index == selectedIndex {
                                        Image(systemName: "return").font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                }.padding(.horizontal, 11).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .themedBackground(ThemeColor(token: .selectedFill, opacity: index == selectedIndex ? 1 : 0))
                            }.buttonStyle(.pressableRow).id(match.id)
                                .accessibilityLabel(match.path).accessibilityIdentifier("quick-open-result-\(index)")
                        }
                    }.padding(7)
                }
                .onChange(of: selectedIndex) { _, index in
                    guard matches.indices.contains(index) else { return }
                    withMotion(Motion.scroll) { proxy.scrollTo(matches[index].id) }
                }
                .onChange(of: query) { _, _ in
                    selectedIndex = 0
                    if let first = matches.first { proxy.scrollTo(first.id, anchor: .top) }
                }
            }
            Divider()
            HStack {
                Text(query.isEmpty ? "最近及项目文件" : "\(matches.count) 个匹配，最多显示 100 个")
                Spacer()
                Text("↑↓ 选择   ↵ 打开   Esc 关闭")
            }.themedFont(.system(size: 11), points: 11).foregroundStyle(.secondary).padding(.horizontal, 15).padding(.vertical, 10)
        }
        .frame(width: 660, height: 440)
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onExitCommand { dismiss() }
        .onAppear { searchFocused = true }
    }

    private func moveSelection(_ delta: Int) {
        guard !matches.isEmpty else { selectedIndex = 0; return }
        selectedIndex = min(max(0, selectedIndex + delta), matches.count - 1)
    }

    private func openSelected() {
        guard matches.indices.contains(selectedIndex) else { return }
        open(matches[selectedIndex])
    }

    private func open(_ match: QuickOpenMatch) {
        onOpen(match)
        dismiss()
    }
}

struct ProjectSearchPanel: View {
    let result: ProjectSearchResult?
    let searching: Bool
    @Binding var query: String
    @Binding var caseSensitive: Bool
    let onSearch: () -> Void
    let onOpen: (ProjectSearchHit) -> Void

    @FocusState private var searchFocused: Bool

    private struct FileGroup: Identifiable {
        let path: String
        var hits: [ProjectSearchHit]
        var id: String { path }
    }

    private var groups: [FileGroup] {
        var groups: [FileGroup] = []
        var indexByPath: [String: Int] = [:]
        for hit in result?.hits ?? [] {
            if let index = indexByPath[hit.path] { groups[index].hits.append(hit) }
            else { indexByPath[hit.path] = groups.count; groups.append(FileGroup(path: hit.path, hits: [hit])) }
        }
        return groups
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索项目中的文本", text: $query)
                    .themedTextField().focused($searchFocused).onSubmit(onSearch)
                    .accessibilityLabel("项目全文搜索").accessibilityIdentifier("project-search-query")
                Toggle("Aa", isOn: $caseSensitive).toggleStyle(.button)
                    .themedFont(.system(size: 12, weight: .semibold, design: .monospaced), points: 12)
                    .help("区分大小写").accessibilityLabel("区分大小写")
                Button("搜索", action: onSearch).disabled(query.isEmpty)
            }.padding(14)
            HStack(spacing: 7) {
                if searching { ProgressView().controlSize(.small); Text("搜索中…") }
                else if let result {
                    Text("\(result.hits.count) 处命中 · \(groups.count) 个文件 · 已读取 \(result.scannedFiles) 个文件")
                } else { Text("按原文搜索 UTF-8 文件，回车执行") }
                Spacer()
            }.themedFont(.system(size: 11), points: 11).foregroundStyle(.secondary).padding(.horizontal, 15).padding(.bottom, 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if groups.isEmpty && !searching {
                        ContentUnavailableView(result == nil ? "搜索当前项目" : "没有找到匹配文本",
                                               systemImage: "doc.text.magnifyingglass",
                                               description: Text("跳过 Git 元数据、链接、依赖目录和大文件。"))
                            .frame(maxWidth: .infinity).padding(.vertical, 25)
                    }
                    ForEach(groups) { group in
                        HStack(spacing: 7) {
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                            Text(group.path).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 5)
                            Text("\(group.hits.count)").foregroundStyle(.secondary)
                        }.themedFont(.system(size: 12, weight: .medium), points: 12).padding(.horizontal, 14).padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.045))
                        ForEach(group.hits) { hit in
                            Button { onOpen(hit) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 9) {
                                    Text("\(hit.line):\(hit.column)")
                                        .themedFont(.system(size: 11, design: .monospaced), points: 11).foregroundStyle(.secondary)
                                        .frame(width: 66, alignment: .trailing)
                                    Text(hit.preview).themedFont(.system(size: 12, design: .monospaced), points: 12)
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 5)
                                }.padding(.leading, 12).padding(.trailing, 14).padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.pressableRow)
                                .accessibilityLabel("\(hit.path)，第 \(hit.line) 行，第 \(hit.column) 列，\(hit.preview)")
                        }
                    }
                }
            }
            if let notice = result?.notice {
                Divider()
                Label(notice, systemImage: result?.isTruncated == true ? "line.3.horizontal.decrease.circle" : "info.circle")
                    .themedFont(.system(size: 11), points: 11).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(12)
            }
        }
        .frame(minWidth: 420, minHeight: 300)
        .onAppear { searchFocused = true }
    }
}
