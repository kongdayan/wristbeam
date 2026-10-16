import Foundation
import Security
import Darwin

struct DeveloperKeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        "Keychain (\(status)): " + ((SecCopyErrorMessageString(status, nil) as String?) ?? "Unable to access saved key")
    }
}

/// User-managed local credentials. Keychain is read only by explicit legacy import.
final class DeveloperSecrets {
    private let directory: URL
    private let lock = NSRecursiveLock()
    init(directory: URL = AppPaths.directory("Developer").appendingPathComponent("Credentials", isDirectory: true)) {
        self.directory = directory
    }
    private func url(_ name: String) throws -> URL {
        guard ["api", "webhook", "certificatePassword"].contains(name) else { throw DeveloperError.invalid("Unknown credential") }
        return directory.appendingPathComponent(name + ".key")
    }
    static func validated(_ text: String) throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~+/=")
        guard (32...512).contains(value.utf8.count), value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw DeveloperError.invalid("密钥需为 32–512 位字母、数字或 -._~+/=，不能包含空格")
        }
        return value
    }
    func load(_ name: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        let file = try url(name)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 4096 else { throw DeveloperError.invalid("Invalid credential file") }
            let data = try Data(contentsOf: file)
            guard let value = String(data: data, encoding: .utf8) else { throw DeveloperError.invalid("Invalid credential encoding") }
            return name == "certificatePassword" ? value : try Self.validated(value)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
    }
    func save(_ value: String, name: String) throws {
        lock.lock(); defer { lock.unlock() }
        let value = name == "certificatePassword" ? value : try Self.validated(value)
        guard value.utf8.count <= 4096 else { throw DeveloperError.invalid("Credential is too long") }
        try GarminPrivateFile.write(Data(value.utf8), to: url(name))
    }
    func key(_ name: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        if let value = try load(name), !value.isEmpty { return value }
        let value = try Self.generate(); try save(value, name: name)
        return value
    }
    /// Export a plain UTF-8 key without changing permissions of the user's folder.
    static func export(_ value: String, to destination: URL) throws {
        let value = try validated(value)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".wristbeam-key-" + UUID().uuidString)
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: Data((value + "\n").utf8)); try handle.synchronize(); try handle.close()
        guard Darwin.rename(temporary.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    static func decoded(status: OSStatus, data: Data?) throws -> String? {
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw DeveloperKeychainError(status: status) }
        guard let data, let value = String(data: data, encoding: .utf8) else { throw DeveloperKeychainError(status: errSecDecode) }
        return value
    }
    static func legacyKey(_ name: String) throws -> String {
        guard ["api", "webhook", "certificatePassword"].contains(name) else { throw DeveloperError.invalid("Unknown credential") }
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:"cn.wenyankong.wristbeam.developer" + (PulseRuntime.isPreview ? ".preview" : ""),
            kSecAttrAccount as String:name, kSecReturnData as String:true, kSecMatchLimit as String:kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard let key = try decoded(status: status, data: result as? Data) else { throw DeveloperError.invalid("未找到旧版密钥") }
        return key
    }
    static func generate() throws -> String {
        var bytes = [UInt8](repeating:0,count:32)
        guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes) == errSecSuccess else { throw DeveloperError.invalid("Secure random generator unavailable") }
        return bytes.map { String(format:"%02x",$0) }.joined()
    }
}
