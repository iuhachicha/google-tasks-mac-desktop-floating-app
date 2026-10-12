import Foundation
import Security
import Darwin

// This probe never searches outside its unique synthetic service/account pair.
// It deliberately uses default macOS Keychain access controls, with no custom ACL.
private let servicePrefix = "com.floattasks.signing-probe."
private let account = "synthetic-fixture"
private let expectedData = Data("Non-secret Float Tasks signing continuity fixture".utf8)

#if PROBE_VERSION_A
private let versionAction = "add"
#elseif PROBE_VERSION_B
private let versionAction = "read"
#else
#error("Compile with PROBE_VERSION_A or PROBE_VERSION_B")
#endif

private func fail(_ stage: String, status: OSStatus? = nil) -> Never {
    let suffix = status.map { " (OSStatus \($0))" } ?? ""
    print("FAIL: \(stage)\(suffix)")
    exit(1)
}

guard CommandLine.arguments.count == 3 else { fail("probe arguments") }
let action = CommandLine.arguments[1]
let service = CommandLine.arguments[2]
guard service.hasPrefix(servicePrefix),
      UUID(uuidString: String(service.dropFirst(servicePrefix.count))) != nil,
      action == versionAction || action == "delete" else {
    fail("probe arguments")
}

// Suppress all Keychain authentication dialogs in this process. The certificate's
// private-key approval, if necessary, belongs to the separate codesign process.
let interactionStatus = SecKeychainSetUserInteractionAllowed(false)
guard interactionStatus == errSecSuccess else {
    fail("suppress Keychain interaction", status: interactionStatus)
}

let match: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: account,
    // Exercise the traditional macOS Keychain's default application ACL and
    // partition checks. A matching designated requirement alone is insufficient.
    kSecUseDataProtectionKeychain as String: false
]

switch action {
case "add":
    var item = match
    item[kSecValueData as String] = expectedData
    item[kSecAttrLabel as String] = "Temporary synthetic signing continuity probe"
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { fail("create synthetic item", status: status) }
    print("PASS: version A created synthetic item without UI")
case "read":
    var query = match
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else { fail("version B read without UI", status: status) }
    guard let data = result as? Data, data == expectedData else { fail("synthetic value mismatch") }
    print("PASS: version B read the same synthetic item without UI")
case "delete":
    let status = SecItemDelete(match as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
        fail("delete synthetic item", status: status)
    }
    // Check absence using attributes only; never print any Keychain contents.
    let checkStatus = SecItemCopyMatching(match as CFDictionary, nil)
    guard checkStatus == errSecItemNotFound else {
        fail("confirm synthetic item removal", status: checkStatus)
    }
    print("PASS: synthetic item removed")
default:
    fail("probe action")
}
