// fanverify.swift — 一次性端到端验证 smctool 风扇控制 (AEWP 提权)
// 流程: faninfo(基线) -> fanset 定速 -> faninfo(确认手动) -> fanset auto -> faninfo(确认恢复)
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

let tool = "/Users/qq/Documents/Dev/mac/Laomac/smctool"

print("── 0. 诊断: 详细失败码 ──")
print(runPriv("\(tool) debug 2>&1"))
print("── 验证结束 ──")
