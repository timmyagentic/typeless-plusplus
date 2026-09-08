import CommonCrypto
import CryptoKit
import Foundation
import TypelessQuietCore

/// Reads only the currently installed client's two session files. Nothing is written back.
/// Format reference: fufu1209/Typeless, scripts/extract-active-session.js (MIT).
struct OfficialQuotaSessionReader: OfficialQuotaSessionReading {
    let directory: URL
    var platformSignature: String = Self.currentPlatformSignature

    private static var currentPlatformSignature: String {
        #if arch(arm64)
        "darwin-arm64"
        #else
        "darwin-x64"
        #endif
    }

    func revision() throws -> String { try input().revision }

    func read() throws -> OfficialQuotaSession {
        let input = try input()
        var clear = try Self.decrypt(input.encrypted, platformSignature: platformSignature)
        defer { clear.resetBytes(in: 0..<clear.count) }
        struct Envelope: Decodable { let userData: String }
        struct Credentials: Decodable {
            let email: String
            let user_id: String
            let access_token: String
        }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: clear)
            let credential = try JSONDecoder().decode(Credentials.self, from: Data(envelope.userData.utf8))
            guard let email = AccountProfile.normalizedEmail(credential.email), email == input.email else {
                throw OfficialQuotaFailure(code: .identityMismatch)
            }
            guard !credential.user_id.isEmpty, credential.user_id.count <= 256,
                  !credential.access_token.isEmpty, credential.access_token.count <= 32_768,
                  !credential.access_token.contains(where: { $0.isWhitespace || $0.isNewline }) else {
                throw OfficialQuotaFailure(code: .invalidSession)
            }
            return OfficialQuotaSession(email: email, userID: credential.user_id,
                accessToken: credential.access_token, revision: input.revision)
        } catch let error as OfficialQuotaFailure { throw error }
        catch { throw OfficialQuotaFailure(code: .invalidSession) }
    }

    private struct Input {
        let encrypted: Data
        let email: String
        var revision: String {
            var data = encrypted
            data.append(contentsOf: email.utf8)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    private func input() throws -> Input {
        do {
            let encrypted = try boundedRead(directory.appendingPathComponent("user-data.json"))
            let state = try TypelessLocalStateParser.parse(
                data: boundedRead(directory.appendingPathComponent("app-storage.json")),
                observedAt: Date(), fileModifiedAt: nil)
            guard let email = state.email else { throw OfficialQuotaFailure(code: .sessionUnavailable) }
            return Input(encrypted: encrypted, email: email)
        } catch let error as OfficialQuotaFailure { throw error }
        catch { throw OfficialQuotaFailure(code: .sessionUnavailable) }
    }

    private func boundedRead(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard !data.isEmpty, data.count <= 1_048_576 else {
            throw OfficialQuotaFailure(code: .invalidSession)
        }
        return data
    }

    static func decrypt(_ data: Data, platformSignature: String) throws -> Data {
        guard ["darwin-arm64", "darwin-x64"].contains(platformSignature),
              data.count >= 33, data.count <= 1_048_576, data[16] == 0x3a,
              (data.count - 17).isMultiple(of: kCCBlockSizeAES128) else {
            throw OfficialQuotaFailure(code: .invalidSession)
        }
        let iv = Data(data.prefix(16))
        let platformHash = SHA256.hash(data: Data(platformSignature.utf8))
            .map { String(format: "%02x", $0) }.joined()
        var base = try derive(Data((platformHash + "Typeless").utf8),
                              salt: Data("typeless-user-service".utf8), prf: CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256))
        defer { base.resetBytes(in: 0..<base.count) }
        // Typeless/Node converts the raw IV to UTF-8 with replacement before deriving this salt.
        var key = try derive(base, salt: Data(String(decoding: iv, as: UTF8.self).utf8),
                             prf: CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512))
        defer { key.resetBytes(in: 0..<key.count) }
        let cipher = Data(data.dropFirst(17))
        var output = Data(count: cipher.count + kCCBlockSizeAES128)
        let capacity = output.count
        var written = 0
        let status = output.withUnsafeMutableBytes { output in
            key.withUnsafeBytes { key in
                iv.withUnsafeBytes { iv in
                    cipher.withUnsafeBytes { cipher in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding), key.baseAddress, kCCKeySizeAES256,
                            iv.baseAddress, cipher.baseAddress, cipher.count, output.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            output.resetBytes(in: 0..<output.count)
            throw OfficialQuotaFailure(code: .invalidSession)
        }
        output.count = written
        return output
    }

    private static func derive(_ password: Data, salt: Data, prf: CCPseudoRandomAlgorithm) throws -> Data {
        var output = Data(count: kCCKeySizeAES256)
        let status = output.withUnsafeMutableBytes { output in
            password.withUnsafeBytes { password in
                salt.withUnsafeBytes { salt in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        password.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                        salt.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        prf, 10_000, output.baseAddress?.assumingMemoryBound(to: UInt8.self), output.count)
                }
            }
        }
        guard status == kCCSuccess else { throw OfficialQuotaFailure(code: .invalidSession) }
        return output
    }
}
