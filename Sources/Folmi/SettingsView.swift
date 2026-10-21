import SwiftUI

/// Settings have a stable app-level entry; appearance controls contain appearance only.
struct FolmiSettingsSheet: View {
    @Bindable var model: FolmiModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TabView {
            VStack(alignment: .leading, spacing: 18) {
                Text("外观").font(.title2.weight(.semibold))
                Form {
                    Picker("明暗", selection: $model.appearance) {
                        ForEach(FolmiAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Menu("配色主题 · \(model.theme.title)") { ThemeMenuItems(model: model) }
                    Toggle("使用玻璃导航表面", isOn: $model.glassSurfaces)
                    Text("辅助功能的减少透明度和增强对比度设置会优先使用实色表面。")
                        .font(.caption).foregroundStyle(.secondary)
                }.formStyle(.grouped)
                settingsFooter
            }.padding(20).tabItem { Label("外观", systemImage: "circle.lefthalf.filled") }

            VStack(alignment: .leading, spacing: 18) {
                Text("编辑器与阅读").font(.title2.weight(.semibold))
                Form {
                    Stepper("编辑器字号：\(Int(model.editorFontSize))", value: $model.editorFontSize, in: 10...32)
                    Toggle("编辑器自动换行", isOn: $model.editorWrapLines)
                    Toggle("在光标所在行显示最后修改人", isOn: $model.editorLineBlame)
                    Text("光标停下后，在这一行末尾用淡色字写出最后改它的人、时间和提交说明；点它可以看这次提交。")
                        .font(.caption).foregroundStyle(.secondary)
                    Menu("Markdown 阅读排版") { MarkdownReadingMenu(model: model) }
                    Text("Markdown 阅读字体、字号和宽度独立于代码编辑器，可按长文阅读习惯调整。")
                        .font(.caption).foregroundStyle(.secondary)
                }.formStyle(.grouped)
                settingsFooter
            }.padding(20).tabItem { Label("编辑器", systemImage: "textformat") }

            AISettingsSheet(model: model).tabItem { Label("AI", systemImage: "sparkles") }
        }
        .padding(12).frame(width: 680).frame(minHeight: 560, idealHeight: 640, maxHeight: 760)
    }

    private var settingsFooter: some View {
        HStack {
            Text("外观与编辑偏好自动保存；AI 设置需点保存。").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
        }
    }
}
