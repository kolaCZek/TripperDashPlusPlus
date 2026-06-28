//
//  K1GCrypto.swift
//  TripperDashPP
//
//  Swift port of the stock app's `edk.g()` field encryption — the AES
//  layer that wraps caller-name (`05 22`) and every incoming-message field
//  (content `0524…`, sender `0527…`, timestamp `052A…`) before they go on
//  the K1G wire.
//
//  Why this is reproducible (not a "crypto wall"): the AES key is NOT a
//  dash secret. The phone GENERATES it (`edk.m()` ⇄ `RsaHandshake.makeAesKey`)
//  and RSA-ships it to the dash inside the `08 00` session-key packet
//  (`edk.j()` ⇄ `RsaHandshake.encryptSessionKey`). So the same key we used
//  to authenticate the projection session — parked in `BikeLink.aesKey` —
//  is exactly the key the dash uses to decrypt these fields. We just have
//  to encrypt with it the same way `edk.g()` does.
//
//  Byte-exact recipe, from `edk.g()` (edk.java:108-138), decompiled
//  2026-06-27. Mirror it faithfully — including the quirks:
//
//    1. For each UTF-16 code unit of the string: unit < 255 → that byte;
//       unit >= 255 → 0xFF. (Stock truncation quirk: anything above U+00FE
//       — most non-Latin-1 diacritics, all emoji surrogates — collapses to
//       0xFF. We reproduce it, we do NOT "fix" it, or the dash-side decrypt
//       parity check breaks.)
//    2. Append a single 0x00 terminator byte.
//    3. AES-256/CBC/PKCS7 encrypt under the 32-byte session key, with a
//       fresh random 16-byte IV.
//    4. Wire payload = IV(16) ‖ ciphertext. (The stock app hex-encodes this
//       and re-packs via lbh.f, so on the wire it's just the raw IV‖ct
//       bytes. We emit the raw bytes directly and skip the hex round-trip.)
//
//  References:
//   - tools/fake_dash/fake_dash/field_crypto.py — the inverse (decrypt),
//     used by the round-trip test.
//   - skills …/references/message-notification-wire-protocol.md
//   - skills …/references/call-notification-wire-protocol.md ("Is the
//     caller-name payload encrypted?")
//

import Foundation
import CommonCrypto

enum K1GCrypto {

    enum CryptoError: Error, LocalizedError {
        case badKeyLength(Int)
        case randomIVFailed(OSStatus)
        case encryptFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .badKeyLength(let n):
                return "K1G field key must be 32 bytes (AES-256), got \(n)"
            case .randomIVFailed(let s):
                return "SecRandomCopyBytes failed for IV (status=\(s))"
            case .encryptFailed(let s):
                return "CCCrypt(AES-CBC) failed (status=\(s))"
            }
        }
    }

    /// AES-CBC block / IV size (16 bytes).
    static let ivLength = kCCBlockSizeAES128  // 16

    /// Encode a string into the stock app's pre-encryption byte form:
    /// one byte per UTF-16 code unit (clamped to 0xFF), plus a trailing
    /// 0x00. Factored out so tests can pin the exact byte mapping
    /// independent of the AES step.
    static func encodePlaintext(_ s: String) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(s.utf16.count + 1)
        for unit in s.utf16 {
            bytes.append(unit < 255 ? UInt8(unit) : 0xFF)
        }
        bytes.append(0x00)  // terminator, exactly like edk.g()
        return Data(bytes)
    }

    /// Encrypt one field exactly like `edk.g()`. Returns the on-wire
    /// payload: `IV(16) ‖ AES-256-CBC-PKCS7(encodePlaintext(s))`.
    ///
    /// `key` must be the 32-byte session key from the RSA handshake
    /// (`BikeLink.aesKey`). A fresh random IV is generated per call, so two
    /// encryptions of the same string differ — which is fine: the IV
    /// travels in the clear at the front, and the dash strips it before
    /// decrypting.
    static func encryptField(_ s: String, key: Data) throws -> Data {
        guard key.count == kCCKeySizeAES256 else {
            throw CryptoError.badKeyLength(key.count)
        }
        var iv = Data(count: ivLength)
        let ivStatus = iv.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, ivLength, $0.baseAddress!)
        }
        guard ivStatus == errSecSuccess else {
            throw CryptoError.randomIVFailed(ivStatus)
        }
        let ciphertext = try aesCBCEncrypt(encodePlaintext(s), key: key, iv: iv)
        return iv + ciphertext
    }

    /// Deterministic variant with a caller-supplied IV — for byte-exact
    /// tests / vector pinning only. Production code uses `encryptField`.
    static func encryptField(_ s: String, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES256 else {
            throw CryptoError.badKeyLength(key.count)
        }
        precondition(iv.count == ivLength, "IV must be \(ivLength) bytes")
        let ciphertext = try aesCBCEncrypt(encodePlaintext(s), key: key, iv: iv)
        return iv + ciphertext
    }

    /// Raw AES-256/CBC/PKCS7 block. Separated so it has one job and is easy
    /// to audit against CommonCrypto semantics.
    private static func aesCBCEncrypt(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        let bufferSize = plaintext.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var numEncrypted = 0

        let status: CCCryptorStatus = buffer.withUnsafeMutableBytes { bufPtr in
            plaintext.withUnsafeBytes { ptPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            ptPtr.baseAddress, plaintext.count,
                            bufPtr.baseAddress, bufferSize,
                            &numEncrypted
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw CryptoError.encryptFailed(status)
        }
        return buffer.prefix(numEncrypted)
    }
}
