import Foundation
import Security
import LocalAuthentication

final class ArchivePasswordStore {
  private let service: String
  private let keychain: SecKeychain?

  init(service: String = "dev.von.f7zip.archive-passwords", keychain: SecKeychain? = nil) {
    self.service = service
    self.keychain = keychain
  }

  private func storageKeychain() throws -> SecKeychain {
    if let keychain = keychain { return keychain }
    var current: SecKeychain?
    try check(SecKeychainCopyDefault(&current))
    guard let current = current else { throw StoreError.keychain(errSecNoDefaultKeychain) }
    return current
  }

  private func requireUnlocked() throws {
    var status: SecKeychainStatus = 0
    try check(SecKeychainGetStatus(try storageKeychain(), &status))
    guard status & UInt32(kSecUnlockStateStatus) != 0 else { throw StoreError.keychain(errSecInteractionNotAllowed) }
  }

  private func query(_ name: String? = nil) throws -> [String: Any] {
    var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    if let name = name { value[kSecAttrAccount as String] = name }
    value[kSecMatchSearchList as String] = [try storageKeychain()]
    return value
  }

  func names() throws -> [String] {
    try requireUnlocked()
    var value = try query()
    value[kSecReturnAttributes as String] = true
    value[kSecMatchLimit as String] = kSecMatchLimitAll
    let context = LAContext()
    context.interactionNotAllowed = true
    value[kSecUseAuthenticationContext as String] = context
    // 传统 macOS 钥匙串的 ACL 交互仍需按查询关闭。
    value[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    var result: CFTypeRef?
    let status = SecItemCopyMatching(value as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    try check(status)
    let entries = result as? [[String: Any]] ?? []
    return entries.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
  }

  func save(name: String, password: String, replace: Bool) throws {
    let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    guard !normalized.isEmpty && normalized.count <= 80 && !password.isEmpty && password.utf8.count <= 4096 else {
      throw StoreError.invalidInput
    }
    let data = Data(password.utf8)
    if replace {
      try check(SecItemUpdate(try query(normalized) as CFDictionary, [kSecValueData as String: data] as CFDictionary))
    } else {
      guard try names().count < 20 else { throw StoreError.tooManyItems }
      var value = try query(normalized)
      value.removeValue(forKey: kSecMatchSearchList as String)
      value[kSecUseKeychain as String] = try storageKeychain()
      value[kSecAttrLabel as String] = normalized
      value[kSecValueData as String] = data
      value[kSecAttrSynchronizable as String] = false
      try check(SecItemAdd(value as CFDictionary, nil))
    }
  }

  func delete(name: String) throws {
    let status = SecItemDelete(try query(name) as CFDictionary)
    if status != errSecItemNotFound { try check(status) }
  }

  func candidates() throws -> [String] {
    var passwords = [String]()
    for name in try names().prefix(20) {
      try requireUnlocked()
      var value = try query(name)
      value[kSecReturnData as String] = true
      value[kSecMatchLimit as String] = kSecMatchLimitOne
      // 自动尝试时跳过需要系统交互的条目，继续使用常规密码输入流程。
      let context = LAContext()
      context.interactionNotAllowed = true
      value[kSecUseAuthenticationContext as String] = context
      value[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
      var result: CFTypeRef?
      let status = SecItemCopyMatching(value as CFDictionary, &result)
      if [errSecItemNotFound, errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains(status) { continue }
      try check(status)
      guard let data = result as? Data, let password = String(data: data, encoding: .utf8), !password.isEmpty else { continue }
      if !passwords.contains(password) { passwords.append(password) }
    }
    return passwords
  }

  private func check(_ status: OSStatus) throws {
    guard status == errSecSuccess else { throw StoreError.keychain(status) }
  }

  enum StoreError: LocalizedError {
    case invalidInput, tooManyItems, keychain(OSStatus)
    var errorDescription: String? {
      switch self {
      case .invalidInput: return "请输入 1–80 字的名称及 1–4096 字节的密码"
      case .tooManyItems: return "最多保存 20 个常用密码，请先删除已有条目"
      case .keychain(errSecDuplicateItem): return "此名称已存在，请选择已有条目更新密码"
      case .keychain(errSecItemNotFound): return "密码条目已变化，请刷新后重试"
      case .keychain(let status): return "钥匙串操作失败（\(status)），请检查钥匙串是否已解锁及访问授权"
      }
    }
  }
}
