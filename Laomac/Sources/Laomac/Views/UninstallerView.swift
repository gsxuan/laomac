import SwiftUI

// MARK: - 应用卸载页 (残留清理思路参考 alienator88/Pearcleaner)

struct UninstallerView: View {
    @EnvironmentObject var app: AppState
    @State private var search = ""
    @State private var confirmUninstall = false

    private var un: UninstallerService { app.uninstaller }

    private var filteredApps: [InstalledApp] {
        search.isEmpty ? un.apps
                       : un.apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                appListCard
                residualCard
                orphanCard
            }
            .padding(20)
        }
        .navigationTitle("应用卸载")
        .onAppear { if un.apps.isEmpty { un.refresh() } }
        .alert("确认卸载", isPresented: $confirmUninstall) {
            Button("卸载并清理", role: .destructive) { un.uninstall {} }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将把「\(un.selected?.name ?? "")」移入废纸篓，并删除 \(un.residuals.count) 项残留文件（\(Shell.humanSize(un.residuals.reduce(0) { $0 + $1.sizeKB }))）")
        }
    }

    // MARK: 已装应用

    private var appListCard: some View {
        Card(title: "已装应用", subtitle: "共 \(un.apps.count) 个 (含 ~/Applications)") {
            HStack {
                TextField("搜索应用…", text: $search)
                    .textFieldStyle(.roundedBorder)
                Button {
                    un.refresh()
                } label: {
                    if un.scanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(un.scanning)
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredApps) { a in
                        Button {
                            un.scanResiduals(for: a)
                        } label: {
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: a.path))
                                    .resizable().frame(width: 26, height: 26)
                                Text(a.name).font(.callout).lineLimit(1)
                                Spacer()
                                Text(Shell.humanSize(a.sizeKB))
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                                if un.selected?.id == a.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.blue)
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(un.selected?.id == a.id
                                        ? Color.blue.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 280)
        }
    }

    // MARK: 选中应用的残留

    private var residualCard: some View {
        Card(title: "残留文件",
             subtitle: un.selected != nil ? "按 Bundle ID / 应用名匹配 ~/Library" : "先在上方选择一个应用") {
            if let sel = un.selected {
                HStack {
                    Text(sel.name).font(.callout.weight(.medium))
                    Spacer()
                    if !un.residuals.isEmpty {
                        Text("\(un.residuals.count) 项 · \(Shell.humanSize(un.residuals.reduce(0) { $0 + $1.sizeKB }))")
                            .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                    }
                    Button("卸载并清理残留…") { confirmUninstall = true }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
                if un.residuals.isEmpty {
                    Text("未发现残留 (扫描完成)")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    ForEach(un.residuals) { r in
                        HStack {
                            Text(r.displayPath)
                                .font(.caption.monospaced()).lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(Shell.humanSize(r.sizeKB))
                                .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } else {
                Text("选择应用后自动扫描其缓存/偏好/容器/日志等残留")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    // MARK: 孤儿残留扫描

    private var orphanCard: some View {
        Card(title: "孤儿残留扫描",
             subtitle: "找出 ~/Library 中与任何已装应用都对不上的条目 (删除前请自行确认)") {
            HStack {
                Button {
                    un.scanOrphans()
                } label: {
                    if un.orphanScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("开始扫描", systemImage: "magnifyingglass")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(un.orphanScanning || un.apps.isEmpty)
                Spacer()
                if !un.orphans.isEmpty {
                    Text("合计 \(Shell.humanSize(un.orphans.reduce(0) { $0 + $1.sizeKB }))")
                        .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                }
            }
            if un.orphanScanning {
                Text("扫描中… (需要读取所有已装应用的 Bundle ID)").font(.caption).foregroundColor(.secondary)
            } else if un.orphans.isEmpty {
                Text("尚未扫描。白名单: com.apple/adobe/microsoft/google/jetbrains 前缀不会被列出")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(un.orphans) { o in
                            HStack {
                                Text(o.displayPath)
                                    .font(.caption.monospaced()).lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(Shell.humanSize(o.sizeKB))
                                    .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                                Button("删除") { un.removeOrphan(o) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .foregroundColor(.red)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
    }
}
