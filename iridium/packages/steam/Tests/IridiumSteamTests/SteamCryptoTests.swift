import Foundation
import XCTest
@testable import IridiumSteam

final class SteamCryptoTests: XCTestCase {
    func testAESHMACIVRoundTrip() throws {
        let key = Data((0..<32).map { UInt8($0) })
        let plaintext = Data("the quick brown fox jumps over the lazy dog".utf8)
        let encrypted = try SteamCrypto.aesEncryptHMACIV(plaintext, key: key)
        let decrypted = try SteamCrypto.aesDecryptHMACIV(encrypted, key: key)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testRSAOAEPEncryptProducesExpectedLength() throws {
        let payload = Data(repeating: 0x42, count: 48)
        let encrypted = try SteamCrypto.rsaEncryptOAEPSHA1(payload)
        // 1024-bit RSA key -> 128-byte ciphertext.
        XCTAssertEqual(encrypted.count, 128)
    }

    func testCRC32MatchesKnownVector() {
        // CRC32("123456789") is a standard test vector.
        let crc = SteamCrypto.crc32(Data("123456789".utf8))
        XCTAssertEqual(crc, 0xCBF4_3926)
    }
}
