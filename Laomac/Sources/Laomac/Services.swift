import Foundation
import SwiftUI

// MARK: - 进程模型与服务

struct ProcessItem: Identifiable {
    let pid: Int32
    let cpu: Double
    let mem: Double
    let name: String
    var id: Int32 { pid }
}

final class ProcessService: ObservableObject {
    @Published var items: [ProcessItem] = []
    @Published var loading = false

    static func readTop(_ limit: Int) -> [ProcessItem] {
        let r = Shell.run("ps -Ao pid=,pcpu=,pmem=,comm= -r | head -n \(limit + 1)")
        var result: [ProcessItem] = []
        for line in r.text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 4,
                  let pid = Int32(parts[0]),
                  let cpu = Double(parts[1]),
                  let mem = Double(parts[2]) else { continue }
            let name = String(parts[3])
                .replacingOccurrences(of: ".app/Contents/MacOS/", with: ".app:")
            result.append(ProcessItem(pid: pid, cpu: cpu, mem: mem, name: name))
        }
        return result
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = ProcessService.readTop(60)
            DispatchQueue.main.async {
                self?.items = items
                self?.loading = false
            }
        }
    }

    /// 结束进程
    func kill(_ pid: Int32, force: Bool = false, _ done: ((Bool) -> Void)? = nil) {
        let r = Shell.run("kill \(force ? "-9" : "-15") \(pid) 2>&1")
        if !r.ok && r.text.contains("permitted") {
            // 需要管理员权限时提权重试
            Shell.runAdminAsync("kill \(force ? "-9" : "-15") \(pid)") { [weak self] res in
                done?(res.ok)
                self?.refresh()
            }
        } else {
            done?(r.ok)
            refresh()
        }
    }

    /// 降低进程优先级 (renice 值越大优先级越低)
    func renice(_ pid: Int32, value: Int = 15, _ done: ((Bool) -> Void)? = nil) {
        let r = Shell.run("renice +\(value) -p \(pid) 2>&1")
        done?(r.ok)
    }
}

// MARK: - 系统信息服务

final class SystemInfoService: ObservableObject {
    @Published var modelName = "--"
    @Published var cpu = "--"
    @Published var coreCount = "--"
    @Published var memory = "--"
    @Published var osVersion = "--"
    @Published var diskUsage = "--"
    @Published var diskPercent: Double = 0
    @Published var purgeableText = "--"   // APFS 可清除空间
    @Published var battery = "--"
    @Published var uptime = "--"
    @Published var memUsage = "--"      // 已用 / 总量
    @Published var memPercent: Double = 0
    @Published var loading = false

    func load() {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let model = Shell.run(
                "system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Model Name/{print $2}'"
            ).text.trimmingCharacters(in: .whitespacesAndNewlines)
            let chip = Shell.run("sysctl -n machdep.cpu.brand_string").text.trimmingCharacters(in: .whitespacesAndNewlines)
            let cores = Shell.run("sysctl -n hw.physicalcpu").text.trimmingCharacters(in: .whitespacesAndNewlines)
            let memKB = Int(Shell.run("sysctl -n hw.memsize").text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            let pageSize = Int(Shell.run("sysctl -n hw.pagesize").text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 16384
            let vm = Shell.run("vm_stat").text
            func pages(_ key: String) -> Double {
                guard let r = vm.range(of: "\(key):\\s+(\\d+)", options: .regularExpression) else { return 0 }
                let num = vm[r].components(separatedBy: ":").last?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
                return Double(num) ?? 0
            }
            let usedBytes = (pages("Pages active") + pages("Pages wired down")
                             + pages("Pages occupied by compressor")) * Double(pageSize)
            let totalBytes = Double(memKB)
            let memPercent = totalBytes > 0 ? usedBytes / totalBytes : 0
            let memUsage = String(format: "%.1f GB / %.0f GB (%.0f%%)",
                                  usedBytes / 1073741824, totalBytes / 1073741824, memPercent * 100)
            let version = Shell.run("sw_vers -productVersion").text.trimmingCharacters(in: .whitespacesAndNewlines)
            // APFS: df -k / 只能读到系统快照卷, 真实数据在 Data 卷; 优先读 Data 卷
            let df = Shell.run("df -k /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $2\" \"$3}'; df -k / | awk 'NR==2{print $2\" \"$3}'").text
            let battery = Shell.run("pmset -g batt | sed -n '2p'").text.trimmingCharacters(in: .whitespacesAndNewlines)
            let uptime = Shell.run("uptime | sed 's/.*up /up /;s/, [0-9]* user.*//'").text.trimmingCharacters(in: .whitespacesAndNewlines)

            var diskText = "--"
            var diskPercent = 0.0
            // df 输出两行 (Data 卷 + 根卷), 取第一行有效数据
            for line in df.split(separator: "\n") {
                let dfParts = line.split(separator: " ")
                if dfParts.count == 2, let total = Double(dfParts[0]), let used = Double(dfParts[1]), total > 0 {
                    diskText = "\(Shell.humanSize(Int(used / 1024))) / \(Shell.humanSize(Int(total / 1024)))"
                    diskPercent = used / total
                    break
                }
            }

            // APFS 可清除空间: important 与 opportunistic 可用容量之差即系统可自动回收的部分
            var purgeableText = "--"
            if let volURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let vals = try? volURL.resourceValues(forKeys: [
                   .volumeAvailableCapacityForImportantUsageKey,
                   .volumeAvailableCapacityForOpportunisticUsageKey]),
               let important = vals.volumeAvailableCapacityForImportantUsage,
               let opportunistic = vals.volumeAvailableCapacityForOpportunisticUsage {
                let purgeable = max(0, important - opportunistic)
                purgeableText = Shell.humanSize(Int(purgeable / 1024))
            }

            DispatchQueue.main.async {
                self?.modelName = model.isEmpty ? "--" : model
                self?.cpu = chip.isEmpty ? "--" : chip
                self?.coreCount = "\(cores) 核心"
                self?.memory = "\(memKB / 1024 / 1024 / 1024) GB"
                self?.memUsage = memUsage
                self?.memPercent = memPercent
                self?.osVersion = "macOS \(version)"
                self?.diskUsage = diskText
                self?.diskPercent = diskPercent
                self?.purgeableText = purgeableText
                self?.battery = battery.isEmpty ? "--" : battery
                self?.uptime = uptime.isEmpty ? "--" : uptime
                self?.loading = false
            }
        }
    }
}

// MARK: - 启动项服务

struct LaunchAgentItem: Identifiable {
    let id = UUID()
    let label: String
    let path: String
    let isUserScope: Bool
    var enabled: Bool

    var disabledPath: String {
        (path as NSString).deletingLastPathComponent + "/.disabled/\(label).plist"
    }
}

final class LaunchAgentsService: ObservableObject {
    @Published var items: [LaunchAgentItem] = []
    @Published var message: String?

    private var userDirs: [String] { [NSHomeDirectory() + "/Library/LaunchAgents"] }
    private var systemDirs: [String] { ["/Library/LaunchAgents"] }

    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var result: [LaunchAgentItem] = []
            for dir in self.userDirs {
                result += self.scan(dir: dir, userScope: true)
            }
            for dir in self.systemDirs {
                result += self.scan(dir: dir, userScope: false)
            }
            DispatchQueue.main.async { self.items = result }
        }
    }

    private func scan(dir: String, userScope: Bool) -> [LaunchAgentItem] {
        var items: [LaunchAgentItem] = []
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return items }
        for file in files.sorted() where file.hasSuffix(".plist") {
            items.append(LaunchAgentItem(label: String(file.dropLast(6)),
                                         path: dir + "/" + file,
                                         isUserScope: userScope,
                                         enabled: true))
        }
        // 已禁用目录中的项
        let disabledDir = dir + "/.disabled"
        if let disabled = try? fm.contentsOfDirectory(atPath: disabledDir) {
            for file in disabled.sorted() where file.hasSuffix(".plist") {
                items.append(LaunchAgentItem(label: String(file.dropLast(6)),
                                             path: disabledDir + "/" + file,
                                             isUserScope: userScope,
                                             enabled: false))
            }
        }
        return items
    }

    /// 启用/禁用启动项: 禁用时先 unload 再移到 .disabled 目录
    /// 系统级 (/Library) 目录无写入权限时自动走管理员通道 (启动时已授权, 不再弹窗)
    func setEnabled(_ item: LaunchAgentItem, enabled: Bool) {
        let fm = FileManager.default
        if enabled {
            let target = (item.path as NSString).deletingLastPathComponent
                .replacingOccurrences(of: "/.disabled", with: "") + "/" + item.label + ".plist"
            var moved = true
            do {
                try fm.moveItem(atPath: item.path, toPath: target)
            } catch {
                moved = !item.isUserScope &&
                    Shell.runAdmin("mv \(Shell.quote(item.path)) \(Shell.quote(target))").ok
            }
            if moved {
                Shell.run("launchctl load \(Shell.quote(target)) 2>/dev/null")
                message = "已启用: \(item.label)"
            } else {
                message = "启用失败: \(item.label) (未获得管理员权限)"
            }
        } else {
            let disabledDir = (item.path as NSString).deletingLastPathComponent + "/.disabled"
            try? fm.createDirectory(atPath: disabledDir, withIntermediateDirectories: true)
            let target = disabledDir + "/" + item.label + ".plist"
            Shell.run("launchctl unload \(Shell.quote(item.path)) 2>/dev/null")
            var moved = true
            do {
                try fm.moveItem(atPath: item.path, toPath: target)
            } catch {
                moved = !item.isUserScope &&
                    Shell.runAdmin("mkdir -p \(Shell.quote(disabledDir)) && mv \(Shell.quote(item.path)) \(Shell.quote(target))").ok
            }
            if moved {
                message = "已禁用: \(item.label) (重启后完全生效)"
            } else {
                message = "禁用失败: \(item.label) (未获得管理员权限)"
            }
        }
        refresh()
    }

    func reveal(_ item: LaunchAgentItem) {
        NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
    }
}

// MARK: - 磁盘分析服务

struct DirUsage: Identifiable {
    let id = UUID()
    let path: String
    let sizeKB: Int
    var displayPath: String { path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
}

final class DiskService: ObservableObject {
    @Published var dirs: [DirUsage] = []
    @Published var bigFiles: [DirUsage] = []
    @Published var scanning = false
    @Published var scanningBigFiles = false

    // Time Machine 本地快照 (APFS 隐形占空间大户)
    @Published var snapshots: [String] = []
    @Published var snapshotLoading = false

    func loadSnapshots() {
        snapshotLoading = true
        Shell.runAsync("tmutil listlocalsnapshots / 2>/dev/null") { [weak self] r in
            guard let self else { return }
            self.snapshotLoading = false
            self.snapshots = r.text.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    /// 删除单个本地快照 (需管理员)
    func deleteSnapshot(_ name: String, _ done: @escaping () -> Void = {}) {
        Shell.runAdminAsync("tmutil deletelocalsnapshots \(Shell.quote(name)) 2>&1") { [weak self] _ in
            self?.loadSnapshots()
            done()
        }
    }

    /// 扫描常用目录大小
    func scan() {
        guard !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let home = NSHomeDirectory()
            let targets = [
                home + "/Library/Caches",
                home + "/Library/Application Support",
                home + "/Library/Containers",
                home + "/Library/Developer",
                home + "/Library/Mail",
                home + "/Downloads",
                home + "/Documents",
                home + "/Desktop",
                home + "/Movies",
                home + "/.Trash",
                "/Applications",
                "/private/var/folders",
            ]
            var result: [DirUsage] = []
            for t in targets {
                let kb = Shell.dirSizeKB(t)
                if kb > 0 { result.append(DirUsage(path: t, sizeKB: kb)) }
            }
            result.sort { $0.sizeKB > $1.sizeKB }
            DispatchQueue.main.async {
                self?.dirs = result
                self?.scanning = false
            }
        }
    }

    /// 查找大文件 (>800MB), 全盘扫描可能耗时
    func scanBigFiles() {
        guard !scanningBigFiles else { return }
        scanningBigFiles = true
        bigFiles = []
        let home = NSHomeDirectory()
        let cmd = "find \(Shell.quote(home)) -xdev -type f -size +800M " +
                  "-exec du -k {} + 2>/dev/null | sort -rn | head -40"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let r = Shell.run(cmd)
            var files: [DirUsage] = []
            for line in r.text.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1)
                if parts.count == 2, let kb = Int(parts[0]) {
                    files.append(DirUsage(path: String(parts[1]), sizeKB: kb))
                }
            }
            DispatchQueue.main.async {
                self?.bigFiles = files
                self?.scanningBigFiles = false
            }
        }
    }
}

// MARK: - 清理服务

struct CleanTarget: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    var sizeKB: Int = 0
}

final class CleanService: ObservableObject {
    @Published var targets: [CleanTarget] = []
    @Published var totalKB: Int = 0
    @Published var scriptLog = ""
    @Published var running = false
    @Published var message: String?

    private static let defaultTargets: [(String, String)] = [
        ("用户缓存", "~/Library/Caches"),
        ("用户日志", "~/Library/Logs"),
        ("废纸篓", "~/.Trash"),
        ("Xcode DerivedData", "~/Library/Developer/Xcode/DerivedData"),
        ("Xcode 模拟器缓存", "~/Library/Developer/CoreSimulator/Caches"),
        ("iOS DeviceSupport", "~/Library/Developer/Xcode/iOS DeviceSupport"),
        ("npm 缓存", "~/.npm"),
        ("yarn 缓存", "~/Library/Caches/Yarn"),
        ("pip 缓存", "~/Library/Caches/pip"),
        ("Gradle 缓存", "~/.gradle/caches"),
        ("CocoaPods 缓存", "~/Library/Caches/CocoaPods"),
        // 开发缓存专项 (参考 mac-cleanup-py)
        ("Xcode Archives", "~/Library/Developer/Xcode/Archives"),
        ("iOS 设备备份", "~/Library/Application Support/MobileSync/Backup"),
        ("Xcode Device Logs", "~/Library/Developer/Xcode/iOS Device Logs"),
        ("Homebrew 缓存", "~/Library/Caches/Homebrew"),
        ("SwiftPM 缓存", "~/Library/Caches/org.swift.swiftpm"),
        ("Maven 仓库", "~/.m2/repository"),
    ]

    private func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var result: [CleanTarget] = []
            for (name, raw) in CleanService.defaultTargets {
                let path = self.expand(raw)
                var t = CleanTarget(name: name, path: path)
                t.sizeKB = Shell.dirSizeKB(path)
                result.append(t)
            }
            let total = result.reduce(0) { $0 + $1.sizeKB }
            DispatchQueue.main.async {
                self.targets = result
                self.totalKB = total
            }
        }
    }

    /// 清理单个目标 (保留目录本身)
    func clean(_ target: CleanTarget, _ done: @escaping (Bool) -> Void) {
        running = true
        let path = target.path
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let r = Shell.run("find \(Shell.quote(path)) -mindepth 1 -delete 2>/dev/null; exit 0")
            DispatchQueue.main.async {
                self?.running = false
                self?.message = r.ok ? "已清理: \(target.name)" : "清理失败: \(target.name)"
                done(r.ok)
                self?.refresh()
            }
        }
    }

    func cleanAll(_ done: @escaping () -> Void) {
        running = true
        message = "正在清理..."
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var freed = 0
            for (name, raw) in CleanService.defaultTargets {
                let path = self.expand(raw)
                freed += Shell.dirSizeKB(path)
                Shell.run("find \(Shell.quote(path)) -mindepth 1 -delete 2>/dev/null; exit 0")
                _ = name
            }
            DispatchQueue.main.async {
                self.running = false
                self.message = "清理完成, 共释放 \(Shell.humanSize(freed))"
                done()
                self.refresh()
            }
        }
    }

    /// 运行项目里的完整优化脚本 (clean -y), 输出显示在控制台
    func runFullScript(scriptPath: String) {
        guard !running else { return }
        running = true
        scriptLog = ""
        Shell.runAsync("bash \(Shell.quote(scriptPath)) clean -y 2>&1") { [weak self] r in
            self?.scriptLog = r.text.isEmpty ? "(无输出)" : r.text
            self?.running = false
            self?.refresh()
        }
    }
}

// MARK: - 应用卸载服务 (参考 alienator88/Pearcleaner 的残留扫描思路)

struct InstalledApp: Identifiable {
    let id: String          // 路径作唯一标识
    let name: String        // 不带 .app 后缀
    let path: String
    let sizeKB: Int
}

struct ResidualItem: Identifiable {
    let id = UUID()
    let path: String
    let sizeKB: Int
    var displayPath: String { path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
}

final class UninstallerService: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var scanning = false
    @Published var residuals: [ResidualItem] = []
    @Published var selected: InstalledApp?
    @Published var orphans: [ResidualItem] = []
    @Published var orphanScanning = false
    @Published var message: String?

    /// 枚举 /Applications 与 ~/Applications 下的应用
    func refresh() {
        guard !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var result: [InstalledApp] = []
            let fm = FileManager.default
            let roots = ["/Applications", NSHomeDirectory() + "/Applications"]
            for root in roots {
                guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
                for e in entries where e.hasSuffix(".app") {
                    let p = root + "/" + e
                    // 跳过子目录里的嵌套 app (如 Xcode 内部组件)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { continue }
                    result.append(InstalledApp(
                        id: p, name: String(e.dropLast(4)), path: p,
                        sizeKB: Shell.dirSizeKB(p)))
                }
            }
            result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                self?.apps = result
                self?.scanning = false
            }
        }
    }

    /// 按 Bundle ID + 应用名扫描 ~/Library 下的残留 (Pearcleaner 的核心思路)
    func scanResiduals(for app: InstalledApp) {
        selected = app
        residuals = []
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let bundleID = Bundle(path: app.path)?.bundleIdentifier ?? ""
            let name = app.name
            let home = NSHomeDirectory()
            // 候选路径模板: 直接用 bundleID 或应用名匹配
            var candidates: [String] = []
            let libDirs = [
                "Library/Application Support", "Library/Caches", "Library/Preferences",
                "Library/Containers", "Library/Group Containers", "Library/Saved Application State",
                "Library/Logs", "Library/HTTPStorages", "Library/WebKit",
            ]
            for d in libDirs {
                let base = home + "/" + d
                guard let entries = try? FileManager.default.contentsOfDirectory(atPath: base) else { continue }
                for e in entries {
                    let lower = e.lowercased()
                    let matched =
                        (!bundleID.isEmpty && lower == bundleID.lowercased()) ||
                        (!bundleID.isEmpty && lower == bundleID.lowercased() + ".plist") ||
                        (!bundleID.isEmpty && lower == bundleID.lowercased() + ".savedstate") ||
                        (!bundleID.isEmpty && lower.contains(bundleID.lowercased())) ||
                        lower == name.lowercased() || lower == name.lowercased() + ".plist"
                    if matched { candidates.append(base + "/" + e) }
                }
            }
            let items = candidates.map { ResidualItem(path: $0, sizeKB: Shell.dirSizeKB($0)) }
                .sorted { $0.sizeKB > $1.sizeKB }
            DispatchQueue.main.async {
                self?.residuals = items
                self?.message = items.isEmpty ? "未发现 \(name) 的残留文件" : nil
            }
        }
    }

    /// 卸载: 应用移入废纸篓 + 删除全部残留
    func uninstall(_ done: @escaping () -> Void) {
        guard let app = selected else { return }
        let items = residuals
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // 应用本体移入废纸篓 (trashItem 抛异常即失败, 兼容新旧 SDK)
            let trashed = (try? FileManager.default.trashItem(
                at: URL(fileURLWithPath: app.path), resultingItemURL: nil)) != nil
            var freed = 0
            for it in items {
                freed += it.sizeKB
                Shell.run("rm -rf \(Shell.quote(it.path)) 2>/dev/null; exit 0")
            }
            DispatchQueue.main.async {
                self?.message = trashed
                    ? "已卸载 \(app.name), 清理残留 \(Shell.humanSize(freed))"
                    : "应用移入废纸篓失败 (可能被占用), 残留已清理 \(Shell.humanSize(freed))"
                self?.selected = nil
                self?.residuals = []
                self?.refresh()
                done()
            }
        }
    }

    /// 孤儿残留扫描: ~/Library 常见目录下与任何已装应用都对不上的条目
    func scanOrphans() {
        guard !orphanScanning else { return }
        orphanScanning = true
        orphans = []
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // 已装应用的名字与 bundleID 集合
            var known = Set<String>()
            for a in self.apps {
                known.insert(a.name.lowercased())
                if let bid = Bundle(path: a.path)?.bundleIdentifier { known.insert(bid.lowercased()) }
            }
            // 系统组件前缀白名单
            let whitePrefixes = ["com.apple", "apple", "group.com.apple", "byhost",
                                 "adobe", "microsoft", "google", "jetbrains"]
            var found: [ResidualItem] = []
            let home = NSHomeDirectory()
            for d in ["Library/Application Support", "Library/Caches", "Library/Containers"] {
                let base = home + "/" + d
                guard let entries = try? FileManager.default.contentsOfDirectory(atPath: base) else { continue }
                for e in entries {
                    let lower = e.lowercased()
                    if known.contains(lower) { continue }
                    if whitePrefixes.contains(where: { lower.hasPrefix($0) }) { continue }
                    // 含 com.xx 格式的条目大概率属于某个已卸载应用
                    guard lower.contains(".") else { continue }
                    let p = base + "/" + e
                    found.append(ResidualItem(path: p, sizeKB: Shell.dirSizeKB(p)))
                }
            }
            found.sort { $0.sizeKB > $1.sizeKB }
            DispatchQueue.main.async {
                self.orphans = Array(found.prefix(60))
                self.orphanScanning = false
                self.message = "扫描到 \(found.count) 个疑似孤儿残留 (删除前请确认对应应用已卸载)"
            }
        }
    }

    /// 删除选中的孤儿残留
    func removeOrphan(_ item: ResidualItem) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            Shell.run("rm -rf \(Shell.quote(item.path)) 2>/dev/null; exit 0")
            DispatchQueue.main.async {
                self?.orphans.removeAll { $0.id == item.id }
                self?.message = "已删除: \(item.displayPath)"
            }
        }
    }
}

// MARK: - 调优服务 (defaults 设置)

struct TuneItem: Identifiable {
    let id = UUID()
    let title: String
    let domain: String
    let key: String
    let onValue: String
    let offValue: String
    var isOn: Bool
}

final class TuneService: ObservableObject {
    @Published var items: [TuneItem] = []
    @Published var message: String?
    @Published var needsRestart = false

    private static let presets: [(String, String, String, String, String)] = [
        // (标题, domain, key, onValue, offValue)
        ("显示所有文件扩展名", "NSGlobalDomain", "AppleShowAllExtensions", "-bool true", "-bool false"),
        ("禁用自动更正", "NSGlobalDomain", "NSAutomaticSpellingCorrectionEnabled", "-bool false", "-bool true"),
        ("禁用智能引号替换", "NSGlobalDomain", "NSAutomaticQuoteSubstitutionEnabled", "-bool false", "-bool true"),
        ("保存对话框默认展开", "NSGlobalDomain", "NSNavPanelExpandedStateForSaveMode", "-bool true", "-bool false"),
        ("Finder 显示路径栏", "com.apple.finder", "ShowPathbar", "-bool true", "-bool false"),
        ("Finder 显示状态栏", "com.apple.finder", "ShowStatusBar", "-bool true", "-bool false"),
        ("Finder 标题栏显示完整路径", "com.apple.finder", "_FXShowPosixPathInTitle", "-bool true", "-bool false"),
        ("Finder 搜索默认当前目录", "com.apple.finder", "FXDefaultSearchScope", "-string SCcf", "-delete"),
        ("Dock 自动隐藏", "com.apple.dock", "autohide", "-bool true", "-bool false"),
        ("Dock 隐藏动画加速", "com.apple.dock", "autohide-time-modifier", "-float 0.15", "-delete"),
        ("最小化使用缩放效果", "com.apple.dock", "mineffect", "-string scale", "-delete"),
        ("截图保存为 JPG", "com.apple.screencapture", "type", "-string jpg", "-string png"),
        ("截图去掉窗口阴影", "com.apple.screencapture", "disable-shadow", "-bool true", "-bool false"),
        ("触控板轻点即点击", "com.apple.AppleMultitouchTrackpad", "Clicking", "-bool true", "-bool false"),
        ("加快键盘重复速度", "NSGlobalDomain", "KeyRepeat", "-int 2", "-int 6"),
    ]

    func refresh() {
        items = TuneService.presets.map { title, domain, key, onValue, offValue in
            let r = Shell.run("defaults read \(domain) \(key) 2>/dev/null")
                .text.trimmingCharacters(in: .whitespacesAndNewlines)
            let expectedOn = onValue.split(separator: " ").last.map(String.init) ?? ""
            let isOn = !r.isEmpty && r == expectedOn
            return TuneItem(title: title, domain: domain, key: key,
                            onValue: onValue, offValue: offValue, isOn: isOn)
        }
    }

    func apply(_ item: TuneItem) {
        let value = item.isOn ? item.onValue : item.offValue
        if value == "-delete" {
            Shell.run("defaults delete \(item.domain) \(item.key) 2>/dev/null")
        } else {
            Shell.run("defaults write \(item.domain) \(item.key) \(value)")
        }
        if item.domain.contains("dock") || item.domain.contains("finder") {
            needsRestart = true
        }
        message = "已应用: \(item.title)"
        refresh()
    }

    func applyAll() {
        for item in items { apply(item) }
        restartServices()
        message = "已应用全部设置"
    }

    func restartServices() {
        Shell.run("killall Dock 2>/dev/null; killall Finder 2>/dev/null")
        needsRestart = false
        message = "Dock / Finder 已重启, 设置生效"
    }
}

// MARK: - 网速监控服务 (en0 实时上下行)

final class NetSpeedService: ObservableObject {
    @Published var downKBs: Double = 0
    @Published var upKBs: Double = 0

    private var timer: Timer?
    private var lastRX: UInt64?
    private var lastTX: UInt64?
    private var lastTime = Date()

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    deinit { timer?.invalidate() }

    private func tick() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let out = Shell.run("netstat -ibn").text
            var rx: UInt64?, tx: UInt64?
            for line in out.split(separator: "\n") {
                let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                // 取 en0 的链路层统计行: Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes
                guard f.count >= 10, f[0] == "en0", f[2].contains("<Link") else { continue }
                rx = UInt64(f[6])
                tx = UInt64(f[9])
                break
            }
            DispatchQueue.main.async {
                let now = Date()
                let dt = max(now.timeIntervalSince(self.lastTime), 0.1)
                if let rx, let tx, let prx = self.lastRX, let ptx = self.lastTX,
                   rx >= prx, tx >= ptx {
                    self.downKBs = Double(rx - prx) / dt / 1024
                    self.upKBs = Double(tx - ptx) / dt / 1024
                }
                self.lastRX = rx
                self.lastTX = tx
                self.lastTime = now
            }
        }
    }

    var speedText: String {
        "↓ \(Self.fmt(downKBs))   ↑ \(Self.fmt(upKBs))"
    }

    static func fmt(_ kb: Double) -> String {
        if kb >= 1024 { return String(format: "%.2f MB/s", kb / 1024) }
        return String(format: "%.0f KB/s", kb)
    }
}
