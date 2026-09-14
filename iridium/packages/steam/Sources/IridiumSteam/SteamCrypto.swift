import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif
import CryptoKit

/// The DER-encoded (X.509 SubjectPublicKeyInfo) RSA public keys Steam uses per universe,
/// used only to encrypt the ephemeral AES session key during the connection handshake.
/// Sourced from SteamKit's `KeyDictionary` (public protocol constant, not a secret).
enum SteamUniverseKey {
    static let publicUniverse: [UInt8] = [
        0x30, 0x81, 0x9D, 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01,
        0x05, 0x00, 0x03, 0x81, 0x8B, 0x00, 0x30, 0x81, 0x87, 0x02, 0x81, 0x81, 0x00, 0xDF, 0xEC, 0x1A,
        0xD6, 0x2C, 0x10, 0x66, 0x2C, 0x17, 0x35, 0x3A, 0x14, 0xB0, 0x7C, 0x59, 0x11, 0x7F, 0x9D, 0xD3,
        0xD8, 0x2B, 0x7A, 0xE3, 0xE0, 0x15, 0xCD, 0x19, 0x1E, 0x46, 0xE8, 0x7B, 0x87, 0x74, 0xA2, 0x18,
        0x46, 0x31, 0xA9, 0x03, 0x14, 0x79, 0x82, 0x8E, 0xE9, 0x45, 0xA2, 0x49, 0x12, 0xA9, 0x23, 0x68,
        0x73, 0x89, 0xCF, 0x69, 0xA1, 0xB1, 0x61, 0x46, 0xBD, 0xC1, 0xBE, 0xBF, 0xD6, 0x01, 0x1B, 0xD8,
        0x81, 0xD4, 0xDC, 0x90, 0xFB, 0xFE, 0x4F, 0x52, 0x73, 0x66, 0xCB, 0x95, 0x70, 0xD7, 0xC5, 0x8E,
        0xBA, 0x1C, 0x7A, 0x33, 0x75, 0xA1, 0x62, 0x34, 0x46, 0xBB, 0x60, 0xB7, 0x80, 0x68, 0xFA, 0x13,
        0xA7, 0x7A, 0x8A, 0x37, 0x4B, 0x9E, 0xC6, 0xF4, 0x5D, 0x5F, 0x3A, 0x99, 0xF9, 0x9E, 0xC4, 0x3A,
        0xE9, 0x63, 0xA2, 0xBB, 0x88, 0x19, 0x28, 0xE0, 0xE7, 0x14, 0xC0, 0x42, 0x89, 0x02, 0x01, 0x11,
    ]
}

enum SteamCryptoError: Error {
    case keyImportFailed
    case encryptFailed
    case decryptFailed
    case hmacMismatch
}

enum SteamCrypto {
    /// Encrypts `data` with the universe's RSA public key using OAEP-SHA1 padding,
    /// matching Steam's `EnvelopeEncryptedConnection.HandleEncryptRequest`.
    static func rsaEncryptOAEPSHA1(_ data: Data, derPublicKey: [UInt8] = SteamUniverseKey.publicUniverse) throws -> Data {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        // SecKey wants the raw RSAPublicKey (PKCS#1) bytes, not the SubjectPublicKeyInfo
        // wrapper; strip the X.509 wrapper by locating the embedded BIT STRING payload.
        guard let pkcs1 = Self.extractPKCS1PublicKey(fromSubjectPublicKeyInfo: derPublicKey) else {
            throw SteamCryptoError.keyImportFailed
        }
        guard let secKey = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else {
            throw SteamCryptoError.keyImportFailed
        }
        guard let cipherText = SecKeyCreateEncryptedData(secKey, .rsaEncryptionOAEPSHA1, data as CFData, &error) else {
            throw SteamCryptoError.encryptFailed
        }
        return cipherText as Data
    }

    private static func extractPKCS1PublicKey(fromSubjectPublicKeyInfo der: [UInt8]) -> Data? {
        // Minimal DER walk: SEQUENCE { SEQUENCE { OID, NULL }, BIT STRING { SEQUENCE { INTEGER, INTEGER } } }
        // We only need the inner BIT STRING's contents (the PKCS#1 RSAPublicKey DER blob).
        var index = 0
        func readLength(_ bytes: [UInt8], _ i: inout Int) -> Int? {
            guard i < bytes.count else { return nil }
            let first = bytes[i]; i += 1
            if first & 0x80 == 0 { return Int(first) }
            let count = Int(first & 0x7F)
            guard count > 0, count <= 4, i + count <= bytes.count else { return nil }
            var length = 0
            for _ in 0..<count { length = (length << 8) | Int(bytes[i]); i += 1 }
            return length
        }
        guard der[index] == 0x30 else { return nil }
        index += 1
        _ = readLength(der, &index)
        guard der[index] == 0x30 else { return nil }
        index += 1
        guard let algLen = readLength(der, &index) else { return nil }
        index += algLen
        guard index < der.count, der[index] == 0x03 else { return nil }
        index += 1
        guard let bitStringLen = readLength(der, &index) else { return nil }
        // First byte of BIT STRING content is the "unused bits" count (0 for keys).
        guard index < der.count, der[index] == 0x00 else { return nil }
        let contentStart = index + 1
        let contentEnd = index + bitStringLen
        guard contentEnd <= der.count else { return nil }
        return Data(der[contentStart..<contentEnd])
    }

    /// AES-256-CBC decrypt where the IV is the first 16 bytes, ECB-decrypted with `key`.
    static func aesDecryptIVFirst(_ data: Data, key: Data) throws -> Data {
        guard data.count >= 16 else { throw SteamCryptoError.decryptFailed }
        let ivCipher = data.prefix(16)
        let iv = try aesECB(ivCipher, key: key, encrypt: false)
        let cbcCipher = data.suffix(from: 16)
        return try aesCBC(cbcCipher, key: key, iv: iv, encrypt: false, pkcs7: true)
    }

    /// AES-256-CBC encrypt with an IV derived from HMAC-SHA1(Random(3) + plaintext), matching
    /// `NetFilterEncryptionWithHMAC`. Returns ECB-encrypted IV (16 bytes) + CBC ciphertext.
    static func aesEncryptHMACIV(_ plaintext: Data, key: Data) throws -> Data {
        let hmacKey = key.prefix(16)
        var random3 = Data(count: 3)
        _ = random3.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 3, $0.baseAddress!) }

        var hmacInput = random3
        hmacInput.append(plaintext)
        let fullHMAC = Data(HMAC<Insecure.SHA1>.authenticationCode(for: hmacInput, using: SymmetricKey(data: hmacKey)))
        var iv = fullHMAC.prefix(13)
        iv.append(random3)

        let encryptedIV = try aesECB(iv, key: key, encrypt: true)
        let cipherText = try aesCBC(plaintext, key: key, iv: iv, encrypt: true, pkcs7: true)
        return encryptedIV + cipherText
    }

    /// AES-256-CBC decrypt with HMAC-verified IV, matching `NetFilterEncryptionWithHMAC.ProcessIncoming`.
    static func aesDecryptHMACIV(_ data: Data, key: Data) throws -> Data {
        let plainWithIV = try aesDecryptIVFirstReturningIV(data, key: key)
        let (plaintext, iv) = plainWithIV
        let hmacKey = key.prefix(16)
        let random3 = iv.suffix(3)
        var hmacInput = random3
        hmacInput.append(plaintext)
        let fullHMAC = Data(HMAC<Insecure.SHA1>.authenticationCode(for: hmacInput, using: SymmetricKey(data: hmacKey)))
        guard fullHMAC.prefix(13) == iv.prefix(13) else { throw SteamCryptoError.hmacMismatch }
        return plaintext
    }

    private static func aesDecryptIVFirstReturningIV(_ data: Data, key: Data) throws -> (Data, Data) {
        guard data.count >= 16 else { throw SteamCryptoError.decryptFailed }
        let ivCipher = data.prefix(16)
        let iv = try aesECB(ivCipher, key: key, encrypt: false)
        let cbcCipher = data.suffix(from: 16)
        let plaintext = try aesCBC(cbcCipher, key: key, iv: iv, encrypt: false, pkcs7: true)
        return (plaintext, iv)
    }

    /// AES-256-ECB, no padding. Used only for the 16-byte IV blocks (never bulk data).
    static func aesECB(_ data: Data, key: Data, encrypt: Bool) throws -> Data {
        try ccCrypt(data, key: key, iv: nil, operation: encrypt ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt),
            options: CCOptions(kCCOptionECBMode))
    }

    /// AES-256-CBC. `pkcs7` controls PKCS7 padding on encrypt; padding is always stripped on decrypt.
    static func aesCBC(_ data: Data, key: Data, iv: Data, encrypt: Bool, pkcs7: Bool) throws -> Data {
        try ccCrypt(data, key: key, iv: iv, operation: encrypt ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt),
            options: pkcs7 ? CCOptions(kCCOptionPKCS7Padding) : 0)
    }

    private static func ccCrypt(_ data: Data, key: Data, iv: Data?, operation: CCOperation, options: CCOptions) throws -> Data {
        var outLength = 0
        var outData = Data(count: data.count + kCCBlockSizeAES128)
        let status = outData.withUnsafeMutableBytes { outBytes -> CCCryptorStatus in
            data.withUnsafeBytes { inBytes -> CCCryptorStatus in
                key.withUnsafeBytes { keyBytes -> CCCryptorStatus in
                    if let iv {
                        return iv.withUnsafeBytes { ivBytes in
                            CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), options,
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                inBytes.baseAddress, data.count,
                                outBytes.baseAddress, outBytes.count, &outLength)
                        }
                    } else {
                        return CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), options,
                            keyBytes.baseAddress, key.count, nil,
                            inBytes.baseAddress, data.count,
                            outBytes.baseAddress, outBytes.count, &outLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw SteamCryptoError.decryptFailed }
        return outData.prefix(outLength)
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1 != 0) ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func adler32(_ data: Data) -> UInt32 {
        var s1: UInt32 = 1
        var s2: UInt32 = 0
        let base: UInt32 = 65521
        for byte in data {
            s1 = (s1 + UInt32(byte)) % base
            s2 = (s2 + s1) % base
        }
        return (s2 << 16) | s1
    }
}
