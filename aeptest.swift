// aeptest.swift — 探测 AuthorizationExecuteWithPrivileges 在本机是否可用
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
print("AuthorizationCreate:", status)

let rightName = strdup("system.privilege.admin")!
var item = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
var rights = AuthorizationRights(count: 1, items: &item)
status = AuthorizationCopyRights(auth!, &rights, &emptyEnv,
                                 [.interactionAllowed, .preAuthorize, .extendRights], nil)
print("AuthorizationCopyRights:", status)
guard status == errAuthorizationSuccess else { exit(1) }

guard let sym = dlsym(dlopen(nil, RTLD_NOW), "AuthorizationExecuteWithPrivileges") else {
    print("dlsym 找不到符号")
    exit(2)
}
let fn = unsafeBitCast(sym, to: AEWP.self)

var argv: [UnsafeMutablePointer<CChar>?] = [strdup("-c"), strdup("id; whoami"), nil]
var pipe: UnsafeMutablePointer<FILE>?
let st = argv.withUnsafeMutableBufferPointer { buf in
    fn(auth!, "/bin/zsh", [], buf.baseAddress, &pipe)
}
print("AEWP status:", st)
if let fp = pipe {
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = fread(&chunk, 1, 4096, fp)
        if n <= 0 { break }
        FileHandle.standardOutput.write(Data(chunk[0..<n]))
    }
    fclose(fp)
} else {
    print("pipe 为空")
}
