cask "laomac" do
  # 单包通用二进制 (arm64 + x86_64), 无需按架构分资产
  version "1.1"

  # 方式 A (推荐, 零维护): 用 latest 固定别名, 不校验哈希
  #   发版脚本 release.sh 会同步上传 Laomac-latest.zip, 因此 URL 永不变
  sha256 :no_check
  url "https://github.com/gsxuan/laomac/releases/latest/download/Laomac-latest.zip"

  # 方式 B (更严格): 固定版本 URL + 每次发版回填哈希
  #   发版后执行 `shasum -a 256 dist/Laomac-<version>.zip` 取结果替换下方 sha256
  # version "1.1"
  # sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  # url "https://github.com/gsxuan/laomac/releases/download/v#{version}/Laomac-#{version}.zip"

  name "Laomac"
  desc "macOS 系统优化与监控工具 (温度/降频监控、SMC 风扇控制、充电限制、清理调优、鼠标手势)"
  homepage "https://github.com/gsxuan/laomac"

  app "Laomac.app"

  postflight do
    # 作者未做 Apple 公证, 去掉隔离标记以免首次打开被 Gatekeeper 拦截
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{staged_path}/Laomac.app"]
  end

  uninstall_preflight do
    system_command "/usr/bin/pkill", args: ["-x", "Laomac"], successful_or: [0, 1]
  end

  uninstall signal: ["TERM", "com.local.laomac"]

  # SMC 风扇/充电功能另需一个 setuid root 组件, 由 app 首次启动时自行申请管理员授权安装;
  # 卸载时一并清掉 (brew 会弹一次提权)
  zap trash: [
    "~/Library/Preferences/com.local.laomac.plist",
    "/Library/PrivilegedHelperTools/com.local.laomac.smctool",
  ]
end
