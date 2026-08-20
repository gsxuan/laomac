// verifyall.swift — 端到端验证 Laomac 所有需要管理员权限的功能 (AEWP 提权)
// 验证项: 提权身份 / SMC 诊断 / 温度传感器 / 风扇信息 / 充电限制键 / 风扇定速往返 / 低功耗模式 / 辅助功能授权
import Foundation
import Security

typealias AEWP = @convention(c) (
    AuthorizationRef,
    UnsafePointer<CChar>,
    AuthorizationFlags,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
) -> OSStatus

var auth: AuthorizationRef?
var emptyEnv = AuthorizationEnvironment(count: 0, items: nil)
var status = AuthorizationCreate(nil, &emptyEnv, [], &auth)
guard status == errAuthorizationSuccess, let auth else { print("AuthorizationCreate 失败, status=\(status)"); exit(1) }

let rightName = strdup("system.privilege.admin")!
var item = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
var rights = AuthorizationRights(count: 1, items: &item)
status = AuthorizationCopyRights(auth, &rights, &emptyEnv,
                                 [.interactionAllowed, .preAuthorize, .extendRights], nil)
guard status == errAuthorizationSuccess else { print("授权被取消"); exit(1) }

guard let sym = dlsym(dlopen(nil, RTLD_NOW), "AuthorizationExecuteWithPrivileges") else {
    print("dlsym 找不到符号"); exit(2)
}
let fn = unsafeBitCast(sym, to: AEWP.self)

func runPriv(_ cmd: String) -> String {
    var argv: [UnsafeMutablePointer<CChar>?] = [strdup("-c"), strdup(cmd), nil]
    defer { argv.compactMap { $0 }.forEach { free($0) } }
    var pipe: UnsafeMutablePointer<FILE>?
    let st = argv.withUnsafeMutableBufferPointer { buf in
        fn(auth, "/bin/zsh", [], buf.baseAddress, &pipe)
    }
    guard st == errAuthorizationSuccess, let fp = pipe else { return "[AEWP 失败 \(st)]" }
    var out = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = fread(&chunk, 1, 4096, fp)
        if n <= 0 { break }
        out.append(chunk, count: n)
    }
    fclose(fp)
    waitpid(-1, nil, 0)
    return String(data: out, encoding: .utf8) ?? ""
}

let tool = "/Users/qq/Documents/Dev/mac/Laomac/dist/Laomac.app/Contents/Resources/smctool"

print("── 1. 提权身份 (uid/euid) ──")
print(runPriv("id"))

print("── 2. SMC 键诊断 (smctool debug) ──")
print(runPriv("\(tool) debug 2>&1"))

print("── 3. 温度传感器 (smctool temps) ──")
print(runPriv("\(tool) temps 2>&1"))

print("── 4. 风扇信息基线 (smctool faninfo) ──")
let fi = runPriv("\(tool) faninfo 2>&1")
print(fi)

print("── 5. 充电限制键 (BCLM / CH0B / CHBI) ──")
print(runPriv("\(tool) read BCLM 2>&1; echo ---; \(tool) read CH0B 2>&1; echo ---; \(tool) read CHBI 2>&1"))

print("── 6. 风扇定速往返测试 (2200 rpm, 3 秒后恢复自动) ──")
print(runPriv("\(tool) fanset 0 2200 2>&1 && sleep 3 && \(tool) faninfo 2>/dev/null && \(tool) fanset auto 2>&1"))

print("── 7. 恢复自动后确认 ──")
print(runPriv("\(tool) faninfo 2>/dev/null"))

print("── 8. 低功耗模式状态 (pmset) ──")
print(runPriv("pmset -g | grep -i lowpowermode; echo exit=$?"))

print("── 9. 辅助功能授权 (TCC, com.local.laomac) ──")
print(runPriv("sqlite3 '/Library/Application Support/com.apple.TCC/TCC.db' \"SELECT service, client, auth_value FROM access WHERE client LIKE '%laomac%';\" 2>&1"))

print("── 验证结束 ──")
