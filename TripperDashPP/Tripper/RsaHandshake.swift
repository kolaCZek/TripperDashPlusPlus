//
//  RsaHandshake.swift
//  TripperDashPP
//
//  Phone-side of the K1G RSA-1024 / PKCS1v1.5 handshake. Runs once per
//  connection lifetime:
//
//    1. We send q3c.e ("give me your pubkey")
//    2. Bike replies with two segments — modulus (07 00) + exponent (07 03)
//    3. We assemble the SecKey, encrypt `ssid + aes_key` with PKCS1v1.5,
//       and ship it as q3c.d (08 00)
//    4. Bike replies with 07 01 01 (auth OK)
//
//  The AES session key is generated locally — `SecRandomCopyBytes` —
//  and kept in `HandshakeOutcome.aesKey` for future encrypted-payload
//  use (Phase 4+).
//
//  References:
//   - tools/fake_dash/fake_dash/rsa_handshake.py (decrypt_session_key
//     is the inverse of what we do here)
//   - better-dash/tripper_app_like_nav.py (NavigationRootFragment.R0)
//

import Foundation
import Security

enum HandshakeError: Error, LocalizedError {
    case modulusWrongLength(Int)
    case secKeyCreationFailed(OSStatus?)
    case encryptionFailed(CFError?)
    case missingSegment(String)
    /// Step 1 got ZERO packets back before the timeout — the dash's K1G
    /// control-plane never answered our initial burst at all (as opposed to
    /// answering with something unparseable). See `ConnectAttemptResult
    /// .bootRaceMissingReply` in BikeLink for why this is treated specially
    /// on a fresh connect.
    case noReplyAtAll(String)
    /// Step 3 (waiting for auth-OK / 07 01 01 after sending the encrypted
    /// session key) timed out despite the dash actively sending OTHER
    /// traffic the whole time (status/telemetry/button-ack broadcasts) —
    /// as opposed to `noReplyAtAll`, where nothing came back at all. Field
    /// evidence (8/2026): a dash still finishing its own internal auth
    /// processing right after boot chatters normally on other segment
    /// types but hasn't gotten to emitting 07/01 yet; retrying the whole
    /// handshake from scratch a few seconds later succeeds. See
    /// `ConnectAttemptResult.bootRaceMissingReply` in BikeLink, which
    /// treats this the same retryable way as `noReplyAtAll`.
    case authNotReady(String)
    case randomBytesFailed(OSStatus)
    /// Preflight caught that the phone isn't on the dash's Wi-Fi network, so
    /// there's no point opening the socket / firing the handshake burst.
    case notOnDashNetwork(expected: String, actual: String?)

    var errorDescription: String? {
        switch self {
        case .modulusWrongLength(let n):
            return "RSA modulus length \(n) B (expected 128)"
        case .secKeyCreationFailed(let s):
            return "SecKeyCreate failed (status=\(s.map(String.init) ?? "nil"))"
        case .encryptionFailed(let err):
            return "RSA encryption failed: \(err.map(String.init(describing:)) ?? "nil")"
        case .missingSegment(let s):
            return "Handshake reply missing segment \(s)"
        case .noReplyAtAll(let s):
            return "No reply from dash: \(s)"
        case .authNotReady(let s):
            return "Dash busy, auth not confirmed yet: \(s)"
        case .randomBytesFailed(let s):
            return "SecRandomCopyBytes failed (status=\(s))"
        case .notOnDashNetwork(let expected, let actual):
            if let actual {
                return "Not on the dash Wi-Fi (expected \"\(expected)\", on \"\(actual)\"). Join the bike's network and try again."
            }
            return "Not on the dash Wi-Fi (expected \"\(expected)\"). Join the bike's network and try again."
        }
    }
}

struct HandshakeOutcome: Sendable {
    /// 32-byte AES-256 session key the bike now also knows.
    let aesKey: Data
    /// SSID bytes we encoded into the encrypted payload.
    let ssid: String
}

enum RsaHandshake {

    /// Build a `SecKey` from the modulus + exponent the bike sends in
    /// segments `07 00` and `07 03`. Wraps the raw integers in a minimal
    /// PKCS#1 RSAPublicKey ASN.1 SEQUENCE, which is the format
    /// `SecKeyCreateWithData` accepts under
    /// `kSecAttrKeyType=kSecAttrKeyTypeRSA` + `kSecAttrKeyClass=kSecAttrKeyClassPublic`.
    static func makePublicKey(modulus: Data, exponent: Data) throws -> SecKey {
        guard modulus.count == K1G.rsaCiphertextLength else {
            throw HandshakeError.modulusWrongLength(modulus.count)
        }

        let der = encodePKCS1RSAPublicKey(modulus: modulus, exponent: exponent)
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 1024,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &error) else {
            throw HandshakeError.secKeyCreationFailed(nil)
        }
        return key
    }

    /// Generate a random 32-byte AES-256 session key.
    static func makeAesKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: K1G.aesKeyLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw HandshakeError.randomBytesFailed(status)
        }
        return Data(bytes)
    }

    /// Encrypt `ssid_utf8 ‖ aes_key` with PKCS1v1.5 under the bike's
    /// public key. Returns exactly 128 B (RSA-1024 ciphertext size).
    static func encryptSessionKey(
        ssid: String,
        aesKey: Data,
        bikePublicKey: SecKey
    ) throws -> Data {
        precondition(aesKey.count == K1G.aesKeyLength)
        var plaintext = Data()
        plaintext.append(contentsOf: ssid.utf8)
        plaintext.append(aesKey)

        var error: Unmanaged<CFError>?
        guard let ct = SecKeyCreateEncryptedData(
            bikePublicKey,
            .rsaEncryptionPKCS1,
            plaintext as CFData,
            &error
        ) else {
            throw HandshakeError.encryptionFailed(error?.takeRetainedValue())
        }
        return ct as Data
    }

    /// Pull modulus and exponent out of a decoded handshake reply.
    static func extractPubkey(from segments: [K1GSegment]) throws -> (modulus: Data, exponent: Data) {
        let modulus = segments.first { $0.type == K1G.SegType.auth.rawValue && $0.sub == K1G.AuthSub.modulus.rawValue }?.payload
        let exponent = segments.first { $0.type == K1G.SegType.auth.rawValue && $0.sub == K1G.AuthSub.exponent.rawValue }?.payload
        guard let modulus else { throw HandshakeError.missingSegment("07 00 (modulus)") }
        guard let exponent else { throw HandshakeError.missingSegment("07 03 (exponent)") }
        return (modulus, exponent)
    }

    /// Detect the auth-OK reply (07 01 01).
    static func isAuthOK(_ segments: [K1GSegment]) -> Bool {
        return segments.contains {
            $0.type == K1G.SegType.auth.rawValue
            && $0.sub == K1G.AuthSub.status.rawValue
            && $0.payload == Data([0x01])
        }
    }

    // MARK: - PKCS#1 RSAPublicKey ASN.1 encoding

    /// Encode `RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }`.
    /// Returns the raw DER bytes (no SubjectPublicKeyInfo wrapper).
    private static func encodePKCS1RSAPublicKey(modulus: Data, exponent: Data) -> Data {
        let modulusDer = encodeASN1Integer(modulus)
        let expDer = encodeASN1Integer(exponent)
        var inner = Data()
        inner.append(modulusDer)
        inner.append(expDer)
        return wrapSequence(inner)
    }

    /// DER-encode a non-negative big-endian integer. Pads a leading 0x00
    /// when the high bit is set (otherwise it'd be interpreted as negative).
    private static func encodeASN1Integer(_ raw: Data) -> Data {
        var body = raw
        // Strip leading zeros, but keep at least one byte (zero literal).
        while body.count > 1 && body[body.startIndex] == 0x00 {
            body = body.advanced(by: 1)
        }
        // Pad to mark non-negative if MSB is set.
        if let first = body.first, first & 0x80 != 0 {
            var padded = Data([0x00])
            padded.append(body)
            body = padded
        }
        var out = Data([0x02])  // INTEGER tag
        out.append(encodeLength(body.count))
        out.append(body)
        return out
    }

    private static func wrapSequence(_ inner: Data) -> Data {
        var out = Data([0x30])  // SEQUENCE tag
        out.append(encodeLength(inner.count))
        out.append(inner)
        return out
    }

    /// DER length encoding (short or long form).
    private static func encodeLength(_ len: Int) -> Data {
        if len < 0x80 {
            return Data([UInt8(len)])
        }
        var bytes: [UInt8] = []
        var n = len
        while n > 0 {
            bytes.insert(UInt8(n & 0xFF), at: 0)
            n >>= 8
        }
        var out = Data([UInt8(0x80 | bytes.count)])
        out.append(contentsOf: bytes)
        return out
    }
}

// Convenience for slicing leading-zero stripping above.
private extension Data {
    func advanced(by n: Int) -> Data {
        return self.subdata(in: self.index(self.startIndex, offsetBy: n)..<self.endIndex)
    }
}
