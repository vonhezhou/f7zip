import Foundation
import Security

struct TestFailure: Error { let message: String }
func require(_ condition: Bool, _ message: String) throws { if !condition { throw TestFailure(message: message) } }

@main
struct StoreTest {
  static func main() throws {
    func stage(_ value: String) { FileHandle.standardOutput.write(Data((value + "\n").utf8)) }
    stage("create")
    let path = CommandLine.arguments[1]
    let secret = "test-value-7ea24d-秘密🔐  "
    let unlockPassword = "isolated-test-keychain"
    var keychain: SecKeychain?
    let status = unlockPassword.withCString { bytes in
      SecKeychainCreate(path, UInt32(unlockPassword.utf8.count), bytes, false, nil, &keychain)
    }
    try require(status == errSecSuccess && keychain != nil, "create isolated keychain")
    defer { if let keychain = keychain { SecKeychainDelete(keychain) } }
    stage("created")
    let store = ArchivePasswordStore(service: "dev.von.f7zip.test." + UUID().uuidString, keychain: keychain)
    try require(try store.names().isEmpty, "initially empty")
    stage("save first")
    try store.save(name: " 常用 ", password: secret, replace: false)
    try require(try store.names() == ["常用"], "normalized name")
    stage("read first")
    try require(try store.candidates() == [secret], "round trip Unicode and trailing spaces")
    do {
      try store.save(name: "常用", password: "replacement", replace: false)
      throw TestFailure(message: "duplicate must fail")
    } catch ArchivePasswordStore.StoreError.keychain(errSecDuplicateItem) {}
    try require(try store.candidates() == [secret], "duplicate preserves password")
    try store.save(name: "常用", password: "updated-password", replace: true)
    try store.save(name: "another", password: "updated-password", replace: false)
    try require(try store.candidates() == ["updated-password"], "deduplicate candidates")
    try store.save(name: "café", password: secret, replace: false)
    do {
      try store.save(name: "cafe\u{301}", password: "replacement", replace: false)
      throw TestFailure(message: "canonical duplicate must fail")
    } catch ArchivePasswordStore.StoreError.keychain(errSecDuplicateItem) {}
    for index in 0..<17 { try store.save(name: "entry-\(index)", password: "value-\(index)", replace: false) }
    try require(try store.names().count == 20, "maximum count")
    do {
      try store.save(name: "extra", password: secret, replace: false)
      throw TestFailure(message: "maximum count must fail")
    } catch ArchivePasswordStore.StoreError.tooManyItems {}
    try store.save(name: "常用", password: secret, replace: true)
    try require(try store.candidates().contains(secret), "update at limit")
    for (name, password) in [("", secret), (String(repeating: "a", count: 81), secret), ("valid", ""), ("valid", String(repeating: "a", count: 4097))] {
      do {
        try store.save(name: name, password: password, replace: true)
        throw TestFailure(message: "invalid input must fail")
      } catch ArchivePasswordStore.StoreError.invalidInput {}
    }
    stage("lock")
    try require(SecKeychainLock(keychain) == errSecSuccess, "lock")
    // 锁定时允许返回空候选或明确失败，操作须在无交互模式下结束。
    do { try require(try store.candidates().isEmpty, "locked keychain yields no secret") }
    catch is ArchivePasswordStore.StoreError {}
    stage("unlock")
    let unlocked = unlockPassword.withCString { SecKeychainUnlock(keychain, UInt32(unlockPassword.utf8.count), $0, true) }
    try require(unlocked == errSecSuccess, "unlock")
    try require(try store.candidates().contains(secret), "retry after unlock")
    stage("delete")
    try store.delete(name: "常用")
    stage("delete")
    try store.delete(name: "常用")
    try require(try !store.names().contains("常用"), "idempotent delete")
    let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
    try require(bytes.range(of: Data(secret.utf8)) == nil, "secret not plaintext on disk")
    print("Keychain CRUD, isolation, duplicates, limits, lock and retry passed")
  }
}
