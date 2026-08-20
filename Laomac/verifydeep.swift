// verifydeep.swift — 深挖三个问题: TCC 可读性 / 风扇手动键写回 / 温度键枚举
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
guard status == errAuthorizationSuccess, let auth else { exit(1) }
let rightName = strdup("system.privilege.admin")!
var item = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
var rights = AuthorizationRights(count: 1, items: &item)
status = AuthorizationCopyRights(auth, &rights, &emptyEnv,
                                 [.interactionAllowed, .preAuthorize, .extendRights], nil)
guard status == errAuthorizationSuccess else { exit(1) }
guard let sym = dlsym(dlopen(nil, RTLD_NOW), "AuthorizationExecuteWithPrivileges") else { exit(2) }
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

print("── A. TCC.db 文件权限与 SIP ──")
print(runPriv("ls -la@O '/Library/Application Support/com.apple.TCC/TCC.db'; csrutil status"))

print("── B. F0Md 写回测试: 写1读回, 再写0读回 ──")
print(runPriv("\(tool) write F0Md 1 2>&1; \(tool) read F0Md 2>&1; \(tool) write F0Md 0 2>&1; \(tool) read F0Md 2>&1; \(tool) faninfo 2>/dev/null"))

print("── C. 重点温度键探测 ──")
print(runPriv("\(tool) debugkey TC0P; \(tool) debugkey TC0D; \(tool) debugkey TC0E; \(tool) debugkey Tm0P 2>&1"))

print("── D. 全量温度键扫描 (tscan, 可能需 1~2 分钟) ──")
print(runPriv("time \(tool) tscan 2>&1"))

print("── E. 风扇目标转速驱动测试: 写 F0Tg=3000 看 F0Ac 是否跟随 ──")
print(runPriv("\(tool) fanset 0 3000 2>/dev/null; sleep 4; \(tool) faninfo 2>/dev/null; \(tool) fanset auto 2>/dev/null; sleep 2; \(tool) faninfo 2>/dev/null"))
