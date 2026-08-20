# Laomac

一款 macOS 系统优化与监控工具：菜单栏常驻 + 主窗口 11 个功能模块，涵盖温度/降频监控、风扇控制、充电限制、空间清理、系统调优、进程与启动项管理、鼠标手势等。

纯 Swift + SwiftPM 构建，**不依赖 Xcode、无第三方 Swift 依赖**，仅需 Command Line Tools。

## 功能

| 模块 | 说明 |
|---|---|
| 系统概览 | 机型/CPU/内存/磁盘/电池/网速实时信息 |
| CPU 降温 | 热状态 + CPU 曲线、多温度传感器（SMC）、高耗进程压制守护（renice/kill）、低功耗模式 |
| 降频监控 | `pmset -g therm` 采样，降频检测与通知推送，风扇手动定速/恢复自动、降频联动拉满风扇 |
| 电源管理 | 电池健康/功率曲线、**充电上限维持模式**（监控循环 + CHBI 禁充键）、定时开关机 |
| 空间清理 | 开发缓存专项清理（Xcode/npm/pip/Homebrew 等）、一键全清、完整优化脚本 |
| 系统调优 | 15 项常用 `defaults` 优化，单项可逆，一键应用 |
| 启动项 | 用户/系统 LaunchAgents 启停（移入 `.disabled` 备份，可恢复） |
| 进程管理 | CPU/内存 Top 排行，结束进程、降低优先级 |
| 磁盘分析 | 常用目录占用排行、大文件扫描 |
| 应用卸载 | 残留文件扫描（Bundle ID + 应用名匹配）、孤儿残留发现 |
| 鼠标手势 | 右键拖动轨迹手势，辅助功能授权后常驻 |

## 系统要求

- macOS 13.0+（`Package.swift` 最低目标）
- Command Line Tools（`xcode-select --install`）
- SMC 相关功能（温度/风扇/充电限制）已在 **Intel + T2 机型（MacBookPro 2018, macOS 15）** 上验证；
  SMC 键因机型固件而异，不支持的键会在界面提示失败，不会损坏系统
- Apple Silicon 机型：监控类功能可用；SMC 键位与 Intel 不同，风扇/充电限制需按机型调整

## 构建与运行

```bash
# 开发模式运行 (自动同步编译 smctool)
./run.sh

# 打包为 Laomac.app (release 编译 + 打包 smctool + 稳定签名)
./build-app.sh
open dist/Laomac.app
```

`build-app.sh` 会用本地自签名证书（首次自动生成于 `signing/`）做**稳定签名**，
保证重编译后辅助功能等 TCC 授权不失效；证书不可用时退回 ad-hoc 签名。

## 权限说明

| 权限 | 用途 | 获取方式 |
|---|---|---|
| 管理员 | SMC 读写、系统级 LaunchAgents、结束系统进程、低功耗模式、定时开关机 | 启动时弹一次系统密码框（`AuthorizationExecuteWithPrivileges` 通道，之后静默复用） |
| 辅助功能 | 鼠标手势全局右键监听 | 系统设置手动授权（稳定签名保证授权持久） |
| 通知 | 降频警告推送 | 系统设置 → 通知 → Laomac |

## 项目结构

```
Sources/Laomac/
├── App.swift              # 入口 / 侧边栏导航 / 菜单栏
├── Services.swift         # 进程 / 系统信息 / 启动项 / 磁盘 / 清理 / 卸载 / 调优 / 网速
├── Thermal.swift          # 温控服务与压制守护
├── ThrottleService.swift  # 降频监控 + 风扇控制器
├── Power.swift            # 电池 / 充电限制维持循环 / 定时开关机
├── Shell.swift            # Shell 执行层 + 管理员授权通道
├── Gesture*.swift         # 鼠标手势引擎与设置
└── Views/                 # 各模块 SwiftUI 视图
smctool.c                  # 极简 AppleSMC 键读写工具 (需 root, 随 app 打包)
macos-optimize.sh          # 完整优化脚本 (打包进 Resources, 供「完整优化脚本」调用)
verifyall.swift 等         # 开发诊断脚本 (含本机绝对路径, 仅供作者调试)
```

## 技术要点

- **smctool**：用户态直连 AppleSMC（IOKit），支持 `read/write/faninfo/fanset/temps/tscan/debug`；
  兼容 fpe2/flt/sp78 编码与 T2 机型的 32 字节 READ_BYTES 要求；
  权限校验用 `geteuid()`（macOS 15 上 AEWP 提权只抬 euid 不抬 uid）
- **充电限制**：无固件百分比键的机型（如 T2）采用成熟软件同款方案——
  10 秒电池采样监控循环 + CHBI 禁充键 + 5% 回差防抖 + 关闭/异常退出自动恢复充电兜底
- **稳定签名**：专用钥匙串 + 自签证书，签名指纹不随重编译变化，TCC 授权一次授予永久有效

## 安全须知

- 风扇定速与 SMC 写操作存在理论风险（如禁充卡死），本项目已内置多重兜底
  （关闭即恢复充电、启动检测残留禁充状态），但**使用仍需自担风险**
- 清理功能删除前请确认目标内容；启动项禁用采用移入 `.disabled` 的可逆方式

## 许可证

[MIT License](LICENSE)

本项目代码为独立实现，未复制任何第三方项目源码；以下开源项目为设计思路/键表参考，在此致谢：

| 项目 | 许可证 | 参考内容 |
|---|---|---|
| [hholtmann/smacFanControl](https://github.com/hholtmann/smacFanControl) | GPL-2.0 | AppleSMC 用户态通信与风扇控制流程 |
| [exelban/stats](https://github.com/exelban/stats) | MIT | SMC 温度传感器键表 |
| [Chris911/iStats](https://github.com/Chris911/iStats) | MIT | 温度键枚举思路 |
| [alienator88/Pearcleaner](https://github.com/alienator88/Pearcleaner) | Fair-code | 应用残留扫描思路 |
| [mac-cleanup/mac-cleanup-py](https://github.com/mac-cleanup/mac-cleanup-py) | Apache-2.0 | 开发缓存清理目标清单 |
| [AppHouseKitchen/AlDente](https://apphousekitchen.com/) | 商业软件 | 充电限制（禁充键 + 监控循环 + 回差）方案 |

> 注：GPL / Fair-code / Apache 项目的**思想与公开文档不受版权保护**，本项目仅参考其公开思路，
> 未复制受版权保护的代码，故可独立采用 MIT 许可。若后续引入任何项目的实际代码，
> 必须遵守对应许可证并在此声明。

## 免责声明

本工具按"现状"提供，不构成任何明示或暗示的担保。对因使用本软件造成的任何硬件、
软件或数据损失，作者不承担责任。修改 SMC 状态、删除系统文件前请确认你理解正在做的事。
