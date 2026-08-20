import Foundation
import Security

// MARK: - Shell 执行层

struct ShellResult {
    let code: Int32
    let text: String
    var ok: Bool { code == 0 }
}

// MARK: - 管理员授权 (启动时输一次密码, 后续提权命令全部复用, 不再弹窗)

final class AdminAuth {
    static let shared = AdminAuth()

    private var authRef: AuthorizationRef?
    private let lock = NSLock()

    /// 确保已授权。未授权时弹出系统密码框 (仅一次), 已授权则直接返回
    @discardableResult
    func ensureAuthorized() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if authRef != nil { return true }

        var auth: AuthorizationRef?
        var emptyEnv = AuthorizationEnvironment(count: 0, items: nil)
        var status = AuthorizationCreate(nil, &emptyEnv, [], &auth)
        guard status == errAuthorizationSuccess, let created = auth else { return false }

        // 预授权 system.privilege.admin, 此处触发唯一一次密码输入
        guard let rightName = strdup("system.privilege.admin") else { return false }
        defer { free(rightName) }
        var item = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
        var rights = AuthorizationRights(count: 1, items: &item)
        let flags: AuthorizationFlags = [.interactionAllowed, .preAuthorize, .extendRights]
        status = AuthorizationCopyRights(created, &rights, &emptyEnv, flags, nil)
        guard status == errAuthorizationSuccess else {
            AuthorizationFree(created, [])
            NSLog("[Laomac] 管理员授权被取消或失败 (\(status))")
            return false
        }

        authRef = created
        NSLog("[Laomac] 管理员授权成功, 后续提权命令不再弹窗")
        return true
    }

    var isAuthorized: Bool {
        lock.lock()
        defer { lock.unlock() }
        return authRef != nil
    }

    /// AuthorizationExecuteWithPrivileges 在 Swift 中被标记为 unavailable,
    /// 但符号仍存在于 Security.framework, 通过 dlsym 动态获取即可调用
    private typealias AEWPFunc = @convention(c) (
        AuthorizationRef,
        UnsafePointer<CChar>,
        AuthorizationFlags,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
        UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus

    private func executePrivileged(_ auth: AuthorizationRef, command: String,
                                   pipe: inout UnsafeMutablePointer<FILE>?) -> OSStatus {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "AuthorizationExecuteWithPrivileges") else {
            return -1
        }
        let fn = unsafeBitCast(symbol, to: AEWPFunc.self)
        guard let cTool = strdup("/bin/zsh"), let cFlag = strdup("-c"), let cCmd = strdup(command) else {
            return -1
        }
        defer { free(cTool); free(cFlag); free(cCmd) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cFlag, cCmd, nil]
        return argv.withUnsafeMutableBufferPointer { buf in
            fn(auth, cTool, [], buf.baseAddress, &pipe)
        }
    }

    /// 以管理员权限执行命令。已授权时静默执行, 未授权时先尝试授权 (会弹密码框)
    func run(_ command: String) -> ShellResult {
        guard ensureAuthorized() else {
            return ShellResult(code: -2, text: "用户取消了授权")
        }
        lock.lock()
        defer { lock.unlock() }
        guard let auth = authRef else {
            return ShellResult(code: -2, text: "用户取消了授权")
        }

        // 先回显子进程 PID, 便于精确 waitpid (避免误收其它子进程)
        let wrapped = "echo $$; { \(command); } 2>&1"

        var pipe: UnsafeMutablePointer<FILE>?
        let status = executePrivileged(auth, command: wrapped, pipe: &pipe)
        guard status == errAuthorizationSuccess, let fp = pipe else {
            NSLog("[Laomac] 提权执行失败 status=\(status) cmd=\(command.prefix(60))")
            return ShellResult(code: Int32(status), text: "提权执行失败 (\(status))")
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = fread(&buffer, 1, buffer.count, fp)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        fclose(fp)

        let text = String(data: data, encoding: .utf8) ?? ""
        // 首行是 PID, 剩余是命令输出
        var childPid: Int32 = -1
        var output = text
        if let nl = text.firstIndex(of: "\n") {
            let first = String(text[text.startIndex..<nl]).trimmingCharacters(in: .whitespaces)
            childPid = Int32(first) ?? -1
            output = String(text[text.index(after: nl)...])
        }

        var waitStatus: Int32 = 0
        if childPid > 0 {
            waitpid(childPid, &waitStatus, 0)
        } else {
            waitpid(-1, &waitStatus, 0)
        }
        let exitCode: Int32 = (waitStatus & 0x7f) == 0 ? (waitStatus >> 8) & 0xff : -1
        if exitCode != 0 {
            NSLog("[Laomac] 提权命令退出码 \(exitCode): \(command.prefix(60)) -> \(output.prefix(120))")
        }
        return ShellResult(code: exitCode, text: output)
    }
}

enum Shell {
    /// 同步执行 shell 命令 (调用方应在后台线程使用)
    @discardableResult
    static func run(_ command: String) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return ShellResult(code: -1, text: error.localizedDescription)
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        return ShellResult(code: process.terminationStatus,
                           text: out.isEmpty ? err : out)
    }

    /// 以管理员权限执行命令: 复用启动时一次性获取的授权, 不再逐次弹密码框
    static func runAdmin(_ command: String) -> ShellResult {
        AdminAuth.shared.run(command)
    }

    /// 在后台执行命令, 完成后回到主线程回调
    static func runAsync(_ command: String, _ completion: @escaping (ShellResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = run(command)
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func runAdminAsync(_ command: String, _ completion: @escaping (ShellResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runAdmin(command)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 目录大小 (KB)
    static func dirSizeKB(_ path: String) -> Int {
        let r = run("du -sk '\(path)' 2>/dev/null | awk '{print $1}'")
        return Int(r.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// KB 转人类可读
    static func humanSize(_ kb: Int) -> String {
        let mb = Double(kb) / 1024
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return "\(kb) KB"
    }

    /// 转义单引号用于 shell 拼接
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - 特权组件 (一次性安装, 之后 SMC 类操作永久免密码)
//
// 原理: 把 smctool 以 setuid root 安装到 /Library/PrivilegedHelperTools/,
// 之后直接执行即是 root, 不再走 AuthorizationExecuteWithPrivileges 弹窗。
// 安装目标由 root 拥有, 普通用户无法篡改。

enum PrivilegedTool {
    static let installPath = "/Library/PrivilegedHelperTools/com.local.laomac.smctool"

    static var installed: Bool {
        FileManager.default.isExecutableFile(atPath: installPath)
    }

    /// 优先用已安装的特权组件 (免提权), 否则回退 Bundle 内版本 (需 AEWP 提权)
    static var activePath: String? {
        if installed { return installPath }
        if let p = Bundle.main.path(forResource: "smctool", ofType: nil),
           FileManager.default.isExecutableFile(atPath: p) { return p }
        let dev = FileManager.default.currentDirectoryPath + "/smctool"
        return FileManager.default.isExecutableFile(atPath: dev) ? dev : nil
    }

    /// 安装 setuid 组件: 仅首次需要管理员授权, 之后所有 SMC 操作不再弹窗
    static func installIfNeeded(_ done: @escaping (Bool) -> Void) {
        if installed { done(true); return }
        guard let src = activePath else { done(false); return }
        let q = installPath
        let cmd = "mkdir -p /Library/PrivilegedHelperTools && " +
                  "cp \(Shell.quote(src)) \(Shell.quote(q)) && " +
                  "chown root:wheel \(Shell.quote(q)) && chmod 4755 \(Shell.quote(q))"
        Shell.runAdminAsync(cmd) { r in
            if r.ok && installed {
                NSLog("[Laomac] 特权组件已安装, 风扇/传感器操作不再需要密码")
            } else {
                NSLog("[Laomac] 特权组件安装失败: \(r.text.prefix(80))")
            }
            done(r.ok && installed)
        }
    }

    /// 根据是否已安装选择执行通道: 已安装直接跑, 未安装走 AEWP 提权
    static func run(_ args: String, _ done: @escaping (ShellResult) -> Void) {
        guard let tool = activePath else {
            DispatchQueue.main.async { done(ShellResult(code: -3, text: "未找到 smctool")) }
            return
        }
        runShell("\(Shell.quote(tool)) \(args)", done)
    }

    /// 任意 shell 命令按安装状态选通道 (用于多条 smctool 组合命令)
    static func runShell(_ command: String, _ done: @escaping (ShellResult) -> Void) {
        if installed {
            Shell.runAsync(command) { r in done(r) }
        } else {
            Shell.runAdminAsync(command) { r in done(r) }
        }
    }
}
