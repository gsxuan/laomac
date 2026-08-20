import SwiftUI

// MARK: - 进程管理页

struct ProcessView: View {
    @EnvironmentObject var app: AppState
    @State private var searchText = ""
    @State private var selection: ProcessItem?
    @State private var confirmKill: ProcessItem?

    private var filtered: [ProcessItem] {
        if searchText.isEmpty { return app.processes.items }
        return app.processes.items.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Top \(app.processes.items.count) 进程 (按 CPU 排序)")
                    .font(.callout).foregroundColor(.secondary)
                Spacer()
                if let p = selection {
                    Button("降低优先级") {
                        app.processes.renice(p.pid) { _ in app.processes.refresh() }
                    }
                    .buttonStyle(.bordered)
                    Button("结束进程", role: .destructive) {
                        confirmKill = p
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
                }
                Button {
                    app.processes.refresh()
                } label: {
                    if app.processes.loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(12)

            Table(filtered, selection: Binding(
                get: { selection?.id },
                set: { id in selection = app.processes.items.first { $0.id == id } }
            )) {
                TableColumn("PID") { p in
                    Text("\(p.pid)").font(.callout.monospacedDigit())
                }
                .width(70)
                TableColumn("CPU %") { p in
                    Text(String(format: "%.1f", p.cpu))
                        .font(.callout.monospacedDigit())
                        .foregroundColor(p.cpu > 100 ? .red : .primary)
                }
                .width(80)
                TableColumn("内存 %") { p in
                    Text(String(format: "%.1f", p.mem))
                        .font(.callout.monospacedDigit())
                }
                .width(80)
                TableColumn("进程") { p in
                    Text(p.name).font(.callout).lineLimit(1)
                }
            }
        }
        .searchable(text: $searchText, prompt: "搜索进程")
        .navigationTitle("进程管理")
        .confirmationDialog("确认结束进程 \(confirmKill?.name ?? "")?",
                            isPresented: Binding(
                                get: { confirmKill != nil },
                                set: { if !$0 { confirmKill = nil } }
                            ),
                            titleVisibility: .visible) {
            Button("强制结束 (kill -9)", role: .destructive) {
                if let p = confirmKill {
                    app.processes.kill(p.pid, force: true)
                    selection = nil
                }
            }
            Button("正常结束 (kill -15)") {
                if let p = confirmKill {
                    app.processes.kill(p.pid, force: false)
                    selection = nil
                }
            }
            Button("取消", role: .cancel) {}
        }
    }
}

// MARK: - 启动项管理页

struct LaunchAgentsView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("共 \(app.launchAgents.items.count) 项 · 禁用后移入 .disabled 目录, 可随时恢复")
                    .font(.callout).foregroundColor(.secondary)
                Spacer()
                Button {
                    app.launchAgents.refresh()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding(12)

            if let msg = app.launchAgents.message {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }

            List {
                Section("用户级启动项 (~/Library/LaunchAgents)") {
                    ForEach(app.launchAgents.items.filter { $0.isUserScope }) { item in
                        agentRow(item)
                    }
                }
                Section("系统级启动项 (/Library/LaunchAgents, 修改需管理员权限)") {
                    ForEach(app.launchAgents.items.filter { !$0.isUserScope }) { item in
                        agentRow(item)
                    }
                }
            }
        }
        .navigationTitle("启动项")
    }

    private func agentRow(_ item: LaunchAgentItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label).font(.callout)
                Text(item.path)
                    .font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            Button {
                app.launchAgents.reveal(item)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("在 Finder 中显示")
            Toggle("", isOn: Binding(
                get: { item.enabled },
                set: { app.launchAgents.setEnabled(item, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 磁盘分析页

struct DiskView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Card(title: "目录占用排行", subtitle: "扫描常用目录 (系统目录可能偏慢)") {
                    if app.disk.scanning {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("扫描中...").font(.caption).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                    } else {
                        let maxSize = app.disk.dirs.first?.sizeKB ?? 1
                        ForEach(app.disk.dirs) { d in
                            VStack(spacing: 4) {
                                HStack {
                                    Text(d.displayPath)
                                        .font(.callout).lineLimit(1)
                                    Spacer()
                                    Text(Shell.humanSize(d.sizeKB))
                                        .font(.callout.monospacedDigit())
                                    Button {
                                        NSWorkspace.shared.open(URL(fileURLWithPath: d.path))
                                    } label: {
                                        Image(systemName: "folder")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("在 Finder 中打开")
                                }
                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(barColor(d.sizeKB, max: maxSize))
                                        .frame(width: max(4, geo.size.width * CGFloat(d.sizeKB) / CGFloat(max(maxSize, 1))))
                                }
                                .frame(height: 6)
                            }
                            .padding(.vertical, 2)
                        }
                        Button {
                            app.disk.scan()
                        } label: {
                            Label("重新扫描", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, 8)
                    }
                }

                Card(title: "大文件扫描",
                     subtitle: "查找家目录下大于 800MB 的文件, 扫描可能需要 1~2 分钟") {
                    HStack {
                        Button {
                            app.disk.scanBigFiles()
                        } label: {
                            if app.disk.scanningBigFiles {
                                ProgressView().controlSize(.small)
                                Text("扫描中...").font(.caption)
                            } else {
                                Label("开始扫描", systemImage: "magnifyingglass")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(app.disk.scanningBigFiles)

                        if !app.disk.bigFiles.isEmpty {
                            Text("找到 \(app.disk.bigFiles.count) 个大文件")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }

                    ForEach(app.disk.bigFiles) { f in
                        HStack {
                            Text(f.displayPath)
                                .font(.caption.monospaced()).lineLimit(1)
                                .textSelection(.enabled)
                            Spacer()
                            Text(Shell.humanSize(f.sizeKB))
                                .font(.callout.monospacedDigit())
                                .foregroundColor(.orange)
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)])
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 1)
                    }
                }

                Card(title: "Time Machine 本地快照",
                     subtitle: "APFS 隐形占空间大户, 系统自动创建; 删除后空间立即回收") {
                    HStack {
                        Button {
                            app.disk.loadSnapshots()
                        } label: {
                            if app.disk.snapshotLoading {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("刷新快照列表", systemImage: "clock.arrow.circlepath")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(app.disk.snapshotLoading)
                        if !app.disk.snapshots.isEmpty {
                            Text("\(app.disk.snapshots.count) 个快照")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    if app.disk.snapshots.isEmpty && !app.disk.snapshotLoading {
                        Text("点「刷新快照列表」查看; 无快照则无需处理")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    ForEach(app.disk.snapshots, id: \.self) { s in
                        HStack {
                            Text(s.replacingOccurrences(of: "com.apple.TimeMachine.", with: "")
                                    .replacingOccurrences(of: ".local", with: ""))
                                .font(.caption.monospaced())
                            Spacer()
                            Button("删除") { app.disk.deleteSnapshot(s) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .foregroundColor(.red)
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("磁盘分析")
        .onAppear { if app.disk.snapshots.isEmpty { app.disk.loadSnapshots() } }
    }

    private func barColor(_ kb: Int, max maxKB: Int) -> Color {
        let ratio = Double(kb) / Double(max(maxKB, 1))
        if ratio > 0.8 { return .red.opacity(0.7) }
        if ratio > 0.4 { return .orange.opacity(0.7) }
        return .blue.opacity(0.6)
    }
}
