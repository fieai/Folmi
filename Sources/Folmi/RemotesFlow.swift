import AppKit
import FolmiCore
import SwiftUI

extension FolmiModel {
    func loadRemotes() async {
        guard let repository, let root = repositoryURL else { return }
        let list = (try? await repository.remotes()) ?? []
        guard repositoryURL == root else { return }
        remoteList = list
    }

    /// `git remote add`, then a quiet fetch so its branches show up. ⌥⌘Z removes it again.
    func addRemote(_ name: String, url: String) {
        guard let repository, let root = repositoryURL else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = "添加远端 \(name)"
        var added = false
        mutate(title, operation: { [weak self] in
            let step = try await repository.addRemote(name, url: url)
            await MainActor.run { self?.pushUndo(title, step) }
            return "已添加远端 \(name)，正在后台取回它的分支。⌥⌘Z 可撤销。"
        }, succeeded: { added = true }, after: { [weak self] in
            Task {
                await self?.loadRemotes()
                if added { await self?.fetchNow(root: root) }
            }
        })
    }

    /// Reads what removing `name` would take away, then asks.
    func askRemoveRemote(_ name: String) {
        guard let repository else { return }
        Task {
            do { remoteRemoval = try await repository.remoteRecord(name) }
            catch { report(error, title: "无法删除远端") }
        }
    }

    func removeRemote(_ name: String) {
        guard let repository else { return }
        remoteRemoval = nil
        let title = "删除远端 \(name)"
        mutate(title, operation: { [weak self] in
            let step = try await repository.removeRemote(name)
            await MainActor.run { self?.pushUndo(title, step) }
            return "已删除远端 \(name)。服务器上的东西没有变。⌥⌘Z 可恢复。"
        }, after: { [weak self] in Task { await self?.loadRemotes() } })
    }
}

/// The project's remotes: where each one is, and adding or removing them.
struct RemotesSheet: View {
    @Bindable var model: FolmiModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""

    var body: some View {
        let remotes = model.remoteList
        let problem = GitRepository.remoteProblem(name: name, url: url, existing: remotes.map(\.name))
        VStack(alignment: .leading, spacing: 12) {
            Text("远端").themedFont(.title3.weight(.semibold), points: 15)
            Text("远端是这个项目放在别处（GitHub、公司的服务器）的副本。推送把提交送过去，取回把别人的提交拿回来。")
                .themedFont(.caption, points: 10).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                if remotes.isEmpty {
                    Text("这个项目还没有远端，在下面添加一个就能推送和取回。").foregroundStyle(.secondary)
                }
                ForEach(remotes) { row($0) }
            }
            .frame(minHeight: 180)
            VStack(alignment: .leading, spacing: 6) {
                Text("添加远端").themedFont(.callout.weight(.medium), points: 12)
                HStack(spacing: 8) {
                    TextField("名字", text: $name).frame(width: 120)
                    TextField("地址，例如 git@github.com:me/app.git", text: $url)
                        .onSubmit { if problem == nil { add() } }
                    Button("添加", action: add).disabled(problem != nil || model.busy)
                }
                .textFieldStyle(.roundedBorder)
                Text(problem.map { name.isEmpty && url.isEmpty ? "填好名字和地址后添加；添加后会在后台取回一次。" : $0 } ?? "添加后会在后台取回一次，不会改动你的文件。")
                    .themedFont(.caption, points: 10).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 460)
        .task(id: model.snapshot?.remotes ?? []) {
            await model.loadRemotes()
            if name.isEmpty, model.remoteList.isEmpty { name = "origin" }
        }
        .confirmationDialog("删除远端「\(model.remoteRemoval?.name ?? "")」？",
                            isPresented: Binding(get: { model.remoteRemoval != nil }, set: { if !$0 { model.remoteRemoval = nil } }),
                            presenting: model.remoteRemoval) { record in
            Button("删除", role: .destructive) { model.removeRemote(record.name) }
            Button("取消", role: .cancel) { model.remoteRemoval = nil }
        } message: { record in
            Text(removalMessage(record))
        }
    }

    private func add() {
        model.addRemote(name, url: url)
        name = ""; url = ""
    }

    private func removalMessage(_ record: RemoteRecord) -> String {
        var text = "只在本机删掉这个远端的地址和它的 \(record.refs.filter { $0.symbolic == nil }.count) 个分支记录，服务器上的东西不受影响。"
        let branches = record.trackingBranches
        if !branches.isEmpty {
            text += "本地分支 \(branches.prefix(3).joined(separator: "、"))\(branches.count > 3 ? " 等 \(branches.count) 个" : "") 跟踪着它，删除后它们不再关联远端分支。"
        }
        return text + "⌥⌘Z 可以全部恢复。"
    }

    private func row(_ remote: GitRemote) -> some View {
        let tracked = model.snapshot?.upstream?.hasPrefix(remote.name + "/") == true
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(remote.name).themedFont(.callout.weight(.medium), points: 12)
                    if tracked {
                        Text("当前分支跟踪").themedFont(.caption2.weight(.semibold), points: 10)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .themedCapsule(ThemeColor(token: .selectedFill))
                    }
                }
                address(remote.pushURL == nil ? nil : "取回", remote.fetchURL)
                if let push = remote.pushURL { address("推送", push) }
            }
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(remote.fetchURL, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.borderless).help("复制地址")
            Button("删除") { model.askRemoveRemote(remote.name) }.controlSize(.small).disabled(model.busy)
                .help("只在本机删掉这个远端，服务器上的东西不受影响；⌥⌘Z 可恢复")
        }
        .padding(.vertical, 2)
    }

    private func address(_ label: String?, _ url: String) -> some View {
        HStack(spacing: 4) {
            if let label { Text(label).themedFont(.caption2, points: 10).foregroundStyle(.secondary) }
            Text(GitRemote.displayURL(url)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }
}
