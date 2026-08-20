import SwiftUI

// MARK: - 系统概览页

struct OverviewView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                statTiles
                HStack(alignment: .top, spacing: 16) {
                    hardwareCard
                    statusCard
                }
                HStack(alignment: .top, spacing: 16) {
                    diskCard
                    quickActionsCard
                }
            }
            .padding(20)
        }
        .navigationTitle("系统概览")
    }

    // MARK: 顶部统计磁贴

    private var statTiles: some View {
        HStack(spacing: 12) {
            StatTile(icon: "cpu", tint: .blue,
                     title: "CPU",
                     value: String(format: "%.0f%%", app.thermal.currentCPU),
                     sub: app.thermal.speedLimit < 100
                         ? "降频 \(app.thermal.speedLimit)%"
                         : app.thermal.thermalText)
            StatTile(icon: "memorychip", tint: .purple,
                     title: "内存",
                     value: String(format: "%.0f%%", app.info.memPercent * 100),
                     sub: app.info.memUsage)
            StatTile(icon: "internaldrive", tint: .orange,
                     title: "磁盘",
                     value: String(format: "%.0f%%", app.info.diskPercent * 100),
                     sub: app.info.diskUsage)
            StatTile(icon: "battery.75", tint: .green,
                     title: "电池",
                     value: String(format: "%.0f%%", app.power.info.percent),
                     sub: app.power.info.powerSource)
        }
    }

    private var hardwareCard: some View {
        Card(title: "硬件信息") {
            InfoRow(label: "机型", value: app.info.modelName)
            InfoRow(label: "处理器", value: app.info.cpu)
            InfoRow(label: "核心数", value: app.info.coreCount)
            InfoRow(label: "内存", value: app.info.memory)
            InfoRow(label: "内存占用", value: app.info.memUsage)
            InfoRow(label: "系统版本", value: app.info.osVersion)
            InfoRow(label: "运行时长", value: app.info.uptime)
        }
    }

    private var statusCard: some View {
        Card(title: "实时状态") {
            HStack(spacing: 10) {
                Circle()
                    .fill(app.thermal.thermalColor)
                    .frame(width: 12, height: 12)
                Text("热状态: \(app.thermal.thermalText)")
                    .font(.callout.weight(.medium))
            }
            InfoRow(label: "CPU 使用率", value: String(format: "%.1f%%", app.thermal.currentCPU))
            InfoRow(label: "降频状态",
                    value: app.thermal.speedLimit >= 100
                        ? "未降频 (100%)"
                        : "⚠️ 正在降频 (限制 \(app.thermal.speedLimit)%)")
            InfoRow(label: "网络速度", value: app.net.speedText)
            InfoRow(label: "电池", value: app.info.battery)
            Button {
                app.info.load()
            } label: {
                Label("刷新信息", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
    }

    private var diskCard: some View {
        Card(title: "存储空间") {
            ProgressView(value: app.info.diskPercent)
                .tint(app.info.diskPercent > 0.9 ? .red : .blue)
            InfoRow(label: "已用空间", value: app.info.diskUsage)
            InfoRow(label: "可清除空间", value: app.info.purgeableText)
            Text("可清除空间 = APFS 可自动回收的部分 (缓存/快照等); 详细占用见「磁盘分析」页")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var quickActionsCard: some View {
        Card(title: "快捷操作") {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    app.clean.cleanAll {}
                } label: {
                    Label("一键清理缓存", systemImage: "trash")
                }
                Button {
                    app.thermal.suppressNow()
                } label: {
                    Label("压制高 CPU 进程", systemImage: "hare")
                }
                Button {
                    app.thermal.refreshSensors()
                } label: {
                    Label("读取温度/风扇", systemImage: "thermometer")
                }
                Button {
                    app.processes.refresh()
                    app.disk.scan()
                } label: {
                    Label("刷新全部数据", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
        }
    }
}

/// 统计磁贴组件
struct StatTile: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String
    let sub: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(tint))
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(sub)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        )
    }
}
