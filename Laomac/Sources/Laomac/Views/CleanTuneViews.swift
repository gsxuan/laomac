import SwiftUI

// MARK: - 空间清理页

struct CleanView: View {
    @EnvironmentObject var app: AppState
    @State private var selected: Set<UUID> = []
    @State private var confirmCleanAll = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Card(title: "可清理项目",
                     subtitle: "合计可释放约 \(Shell.humanSize(app.clean.totalKB))") {
                    ForEach(app.clean.targets) { t in
                        HStack {
                            Image(systemName: selected.contains(t.id)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(selected.contains(t.id) ? .blue : .secondary)
                            Text(t.name).font(.callout)
                            Text(t.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.caption).foregroundColor(.secondary).lineLimit(1)
                            Spacer()
                            Text(Shell.humanSize(t.sizeKB))
                                .font(.callout.monospacedDigit())
                                .foregroundColor(t.sizeKB > 1024 * 1024 ? .orange : .primary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selected.contains(t.id) { selected.remove(t.id) }
                            else { selected.insert(t.id) }
                        }
                        .padding(.vertical, 2)
                        if t.id != app.clean.targets.last?.id { Divider() }
                    }

                    HStack {
                        Button(selected.count == app.clean.targets.count ? "取消全选" : "全选") {
                            if selected.count == app.clean.targets.count {
                                selected.removeAll()
                            } else {
                                selected = Set(app.clean.targets.map(\.id))
                            }
                        }
                        Spacer()
                        Button {
                            cleanSelected()
                        } label: {
                            if app.clean.running {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("清理所选 (\(selected.count))", systemImage: "trash")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(selected.isEmpty || app.clean.running)

                        Button {
                            confirmCleanAll = true
                        } label: {
                            Label("一键全部清理", systemImage: "trash.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(app.clean.running)
                    }
                    .padding(.top, 8)
                }

                scriptCard

                if let msg = app.clean.message {
                    Text(msg)
                        .font(.callout)
                        .foregroundColor(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
        .navigationTitle("空间清理")
        .confirmationDialog("确认清理全部缓存?",
                            isPresented: $confirmCleanAll,
                            titleVisibility: .visible) {
            Button("清理全部", role: .destructive) {
                app.clean.cleanAll {}
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func cleanSelected() {
        let targets = app.clean.targets.filter { selected.contains($0.id) }
        for t in targets {
            app.clean.clean(t) { _ in }
        }
        selected.removeAll()
    }

    private var scriptCard: some View {
        Card(title: "完整优化脚本",
             subtitle: "调用项目中的 macos-optimize.sh (clean -y), 输出显示在下方") {
            HStack {
                Button {
                    app.clean.runFullScript(scriptPath: Self.scriptPath)
                } label: {
                    Label(app.clean.running ? "运行中..." : "运行清理脚本", systemImage: "terminal")
                }
                .buttonStyle(.bordered)
                .disabled(app.clean.running)

                Button("清空日志") { app.clean.scriptLog = "" }
                    .buttonStyle(.bordered)
                    .disabled(app.clean.scriptLog.isEmpty)
            }
            if !app.clean.scriptLog.isEmpty {
                ScrollView {
                    Text(app.clean.scriptLog)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 200)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
            }
        }
    }

    /// 脚本位置: 优先环境变量, 其次 app 内置资源, 最后运行目录
    static var scriptPath: String {
        if let env = ProcessInfo.processInfo.environment["MAC_OPT_SCRIPT"] { return env }
        if let res = Bundle.main.resourcePath {
            let bundled = res + "/macos-optimize.sh"
            if FileManager.default.fileExists(atPath: bundled) { return bundled }
        }
        return FileManager.default.currentDirectoryPath + "/macos-optimize.sh"
    }
}

// MARK: - 系统调优页

struct TuneView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Card(title: "系统调优",
                     subtitle: "通过 defaults 修改, 每项独立生效且可随时关闭") {
                    ForEach(app.tune.items) { item in
                        TuneRow(item: item) { newValue in
                            if let idx = app.tune.items.firstIndex(where: { $0.id == item.id }) {
                                app.tune.items[idx].isOn = newValue
                                app.tune.apply(app.tune.items[idx])
                            }
                        }
                        if item.id != app.tune.items.last?.id { Divider() }
                    }

                    HStack {
                        if let msg = app.tune.message {
                            Text(msg).font(.caption).foregroundColor(.green)
                        }
                        Spacer()
                        if app.tune.needsRestart {
                            Button("重启 Dock / Finder 生效") {
                                app.tune.restartServices()
                            }
                            .buttonStyle(.bordered)
                        }
                        Button("刷新状态") { app.tune.refresh() }
                            .buttonStyle(.bordered)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(20)
        }
        .navigationTitle("系统调优")
    }
}

private struct TuneRow: View {
    let item: TuneItem
    let onChange: (Bool) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.callout)
                Text("\(item.domain) \(item.key)")
                    .font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { item.isOn },
                set: { onChange($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(.vertical, 2)
    }
}
