import Foundation
import Security

// MARK: - CA Error
enum CAError: Error, LocalizedError {
    case keyGenerationFailed(OSStatus)
    case certCreationFailed
    case keychainError(OSStatus)
    case encodingError
    case notAvailable

    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed(let s): return "Key generation failed: \(s)"
        case .certCreationFailed: return "Certificate creation failed"
        case .keychainError(let s): return "Keychain error: \(s)"
        case .encodingError: return "Encoding error"
        case .notAvailable: return "CA not available"
        }
    }
}

// MARK: - Certificate Authority Manager
actor CertificateAuthorityManager {

    static let shared = CertificateAuthorityManager()

    private let caLabel = "FlowProxy CA"
    private let caTagData = "com.flowproxy.ca".data(using: .utf8)!

    private var caCertificate: SecCertificate?
    private var caPrivateKey: SecKey?
    private var certCache: [String: SecIdentity] = [:]

    // MARK: - Initialization

    func initialize() async throws {
        if let (cert, key) = loadCAFromKeychain() {
            caCertificate = cert
            caPrivateKey = key
            print("[CA] Loaded existing CA from Keychain")
        } else {
            print("[CA] Generating new CA certificate...")
            try await generateCA()
            print("[CA] CA generated successfully")
        }
    }

    var isReady: Bool {
        caCertificate != nil && caPrivateKey != nil
    }

    func getCACertificate() -> SecCertificate? { caCertificate }

    // MARK: - CA Generation

    private func generateCA() async throws {
        // Generate EC key pair for CA
        let keyAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrLabel as String: caLabel,
            kSecAttrIsPermanent as String: false
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyAttrs as CFDictionary, &error) else {
            throw CAError.keyGenerationFailed(errSecParam)
        }

        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw CAError.keyGenerationFailed(errSecParam)
        }

        // Build self-signed CA certificate using ASN.1 DER encoding
        guard let certData = buildSelfSignedCACert(publicKey: publicKey, privateKey: privateKey) else {
            throw CAError.certCreationFailed
        }

        guard let cert = SecCertificateCreateWithData(nil, certData as CFData) else {
            throw CAError.certCreationFailed
        }

        // Store in keychain
        try storeCAInKeychain(cert: cert, privateKey: privateKey)

        caCertificate = cert
        caPrivateKey = privateKey
    }

    // MARK: - Keychain Storage

    private func storeCAInKeychain(cert: SecCertificate, privateKey: SecKey) throws {
        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: caLabel
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let deleteKeyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: caTagData
        ]
        SecItemDelete(deleteKeyQuery as CFDictionary)

        // Store certificate
        let certAttrs: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
            kSecAttrLabel as String: caLabel
        ]
        let status = SecItemAdd(certAttrs as CFDictionary, nil)
        if status != errSecSuccess && status != errSecDuplicateItem {
            throw CAError.keychainError(status)
        }

        // Store private key
        let keyAttrs: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: privateKey,
            kSecAttrLabel as String: caLabel,
            kSecAttrApplicationTag as String: caTagData,
            kSecAttrIsPermanent as String: true
        ]
        let keyStatus = SecItemAdd(keyAttrs as CFDictionary, nil)
        if keyStatus != errSecSuccess && keyStatus != errSecDuplicateItem {
            throw CAError.keychainError(keyStatus)
        }
    }

    private func loadCAFromKeychain() -> (SecCertificate, SecKey)? {
        // Load certificate
        let certQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: caLabel,
            kSecReturnRef as String: true
        ]
        var certResult: CFTypeRef?
        guard SecItemCopyMatching(certQuery as CFDictionary, &certResult) == errSecSuccess,
              let cert = certResult as! SecCertificate? else {
            return nil
        }

        // Load private key
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: caTagData,
            kSecReturnRef as String: true
        ]
        var keyResult: CFTypeRef?
        guard SecItemCopyMatching(keyQuery as CFDictionary, &keyResult) == errSecSuccess,
              let key = keyResult as! SecKey? else {
            return nil
        }

        return (cert, key)
    }

    // MARK: - Per-Domain Certificate

    func getIdentity(for hostname: String) throws -> SecIdentity {
        if let cached = certCache[hostname] {
            return cached
        }

        guard let caCert = caCertificate, let caKey = caPrivateKey else {
            throw CAError.notAvailable
        }

        // Generate leaf key directly into the keychain (kSecAttrIsPermanent: true).
        // This is critical: keys created with kSecAttrIsPermanent: false and later added
        // via SecItemAdd do NOT get kSecAttrApplicationLabel set, so macOS can't match
        // them against a certificate's SubjectPublicKey to form an identity pairing.
        let leafKeyLabel = "com.flowproxy.leaf.\(UUID().uuidString)"
        let keyAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrLabel as String: leafKeyLabel,
            kSecAttrIsPermanent as String: true
        ]
        var error: Unmanaged<CFError>?
        guard let leafPrivKey = SecKeyCreateRandomKey(keyAttrs as CFDictionary, &error) else {
            throw CAError.keyGenerationFailed(errSecParam)
        }
        guard let leafPubKey = SecKeyCopyPublicKey(leafPrivKey) else {
            throw CAError.keyGenerationFailed(errSecParam)
        }

        // Build leaf certificate signed by CA
        guard let leafCertData = buildLeafCert(hostname: hostname,
                                                 leafPublicKey: leafPubKey,
                                                 caPrivateKey: caKey,
                                                 caCert: caCert) else {
            throw CAError.certCreationFailed
        }

        guard let leafCert = SecCertificateCreateWithData(nil, leafCertData as CFData) else {
            throw CAError.certCreationFailed
        }

        // Create identity by storing leaf cert + key temporarily
        // We use an in-memory keychain approach via SecIdentityRef creation
        let identity = try createIdentity(cert: leafCert, privateKey: leafPrivKey)
        certCache[hostname] = identity
        return identity
    }

    private func createIdentity(cert: SecCertificate, privateKey: SecKey) throws -> SecIdentity {
        let uniqueLabel = "com.flowproxy.leaf.\(UUID().uuidString)"
        let ourCertData = SecCertificateCopyData(cert) as Data

        // Add cert and key to the keychain. macOS pairs them automatically by matching
        // the cert's SubjectPublicKey hash against the key's kSecAttrApplicationLabel.
        let certAttrs: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
            kSecAttrLabel as String: uniqueLabel
        ]
        let certStatus = SecItemAdd(certAttrs as CFDictionary, nil)
        print("[CA] certAdd status=\(certStatus) label=\(uniqueLabel)")
        guard certStatus == errSecSuccess || certStatus == errSecDuplicateItem else {
            throw CAError.keychainError(certStatus)
        }

        let keyAttrs: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: privateKey,
            kSecAttrLabel as String: uniqueLabel
        ]
        let keyStatus = SecItemAdd(keyAttrs as CFDictionary, nil)
        print("[CA] keyAdd status=\(keyStatus) label=\(uniqueLabel)")
        guard keyStatus == errSecSuccess || keyStatus == errSecDuplicateItem else {
            SecItemDelete([kSecClass: kSecClassCertificate,
                           kSecAttrLabel: uniqueLabel] as CFDictionary)
            throw CAError.keychainError(keyStatus)
        }

        // Diagnostic: confirm macOS can extract the public key from our cert.
        // If nil, the SubjectPublicKeyInfo encoding is malformed and pairing will fail.
        let extractedKey = SecCertificateCopyKey(cert)
        print("[CA] SecCertificateCopyKey=\(extractedKey != nil ? "OK" : "FAILED — cert public key unreadable")")

        // Query ALL identities and find the one whose cert DER matches ours.
        // (Label/ref-based identity queries on macOS ignore filters and return
        //  the first identity found, which is typically the code-signing cert.)
        let allQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var allRef: CFTypeRef?
        let queryStatus = SecItemCopyMatching(allQuery as CFDictionary, &allRef)
        print("[CA] identityQuery status=\(queryStatus)")

        if queryStatus == errSecSuccess {
            let items: [SecIdentity]
            if let arr = allRef as? [SecIdentity] {
                items = arr
            } else if let single = allRef {
                items = [single as! SecIdentity]
            } else {
                items = []
            }
            print("[CA] found \(items.count) identities in keychain")
            for identity in items {
                var idCert: SecCertificate?
                guard SecIdentityCopyCertificate(identity, &idCert) == errSecSuccess,
                      let idCert = idCert else { continue }
                if (SecCertificateCopyData(idCert) as Data) == ourCertData {
                    print("[CA] matched our leaf cert — identity OK")
                    return identity
                }
            }
        }

        print("[CA] createIdentity: no matching identity found — cert/key pairing failed")
        throw CAError.certCreationFailed
    }

    // MARK: - CA Export

    func exportCACertificatePEM() -> String? {
        guard let cert = caCertificate else { return nil }
        let der = SecCertificateCopyData(cert) as Data
        let b64 = der.base64EncodedString(options: [.lineLength64Characters])
        return "-----BEGIN CERTIFICATE-----\n\(b64)\n-----END CERTIFICATE-----\n"
    }

    func exportCACertificateDER() -> Data? {
        guard let cert = caCertificate else { return nil }
        return SecCertificateCopyData(cert) as Data
    }

    func installCAInSystemKeychain() async throws {
        guard let cert = caCertificate else { throw CAError.notAvailable }

        // Add to System Roots keychain with trust
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
            kSecAttrLabel as String: "\(caLabel) - Trust"
        ]
        _ = SecItemAdd(addQuery as CFDictionary, nil)

        // Set trust settings (requires admin)
        let trustSettings: NSArray = [
            [
                kSecTrustSettingsResult as String: SecTrustSettingsResult.trustRoot.rawValue
            ] as NSDictionary
        ]
        let status = SecTrustSettingsSetTrustSettings(cert, .user, trustSettings as CFTypeRef)
        if status != errSecSuccess {
            throw CAError.keychainError(status)
        }
    }

    // MARK: - ASN.1 DER Certificate Building

    /// Build a minimal self-signed CA certificate in DER format
    private func buildSelfSignedCACert(publicKey: SecKey, privateKey: SecKey) -> Data? {
        let serialNumber: [UInt8] = [0x01]
        let subject = buildDNSequence(cn: "FlowProxy CA", o: "FlowProxy", c: "US")
        let validity = buildValidity(notBefore: Date(), notAfter: Date().addingTimeInterval(10 * 365 * 24 * 3600))

        guard let pubKeyData = extractPublicKeyDER(from: publicKey) else { return nil }

        // Extensions: Basic Constraints (CA: true), Key Usage
        let basicConstraints = buildBasicConstraintsExt(isCA: true)
        let keyUsage = buildKeyUsageExt(bits: 0x86) // keyCertSign + cRLSign + digitalSignature

        let extensions = derSequence(tag: 0xA3,
                                      value: Data(derSequence(tag: 0x30, value: Data(basicConstraints + keyUsage))))

        let tbsCert = buildTBSCertificate(
            serialNumber: serialNumber,
            issuer: Data(subject),
            subject: Data(subject),
            validity: validity,
            publicKeyData: pubKeyData,
            extensions: extensions
        )

        // Sign with ECDSA-SHA256
        guard let signature = signData(Data(tbsCert), with: privateKey) else { return nil }

        // Algorithm identifier: ecPublicKey with SHA256
        let sigAlg = buildECDSAWithSHA256AlgId()
        let sigBitString = derBitString(signature)

        let cert = derSequence(tag: 0x30, value: Data(tbsCert) + Data(sigAlg) + Data(sigBitString))
        return Data(cert)
    }

    /// Build a leaf certificate signed by the CA
    private func buildLeafCert(hostname: String, leafPublicKey: SecKey,
                                 caPrivateKey: SecKey, caCert: SecCertificate) -> Data? {
        let serialBytes: [UInt8] = withUnsafeBytes(of: UInt64.random(in: 1..<UInt64.max).bigEndian) { Array($0) }
        let subject = buildDNSequence(cn: hostname, o: "FlowProxy", c: "US")

        // Extract issuer from CA cert
        let caSubject = extractSubjectDER(from: caCert) ?? buildDNSequence(cn: "FlowProxy CA", o: "FlowProxy", c: "US")

        let validity = buildValidity(notBefore: Date().addingTimeInterval(-60),
                                      notAfter: Date().addingTimeInterval(365 * 24 * 3600))

        guard let pubKeyData = extractPublicKeyDER(from: leafPublicKey) else { return nil }

        // SAN extension for the hostname
        let san = buildSANExt(hostname: hostname)
        let extKeyUsage = buildExtKeyUsageExt()
        let extensions = derSequence(tag: 0xA3,
                                      value: Data(derSequence(tag: 0x30, value: Data(san + extKeyUsage))))

        let tbsCert = buildTBSCertificate(
            serialNumber: serialBytes,
            issuer: Data(caSubject),
            subject: Data(subject),
            validity: validity,
            publicKeyData: pubKeyData,
            extensions: extensions
        )

        guard let signature = signData(Data(tbsCert), with: caPrivateKey) else { return nil }

        let sigAlg = buildECDSAWithSHA256AlgId()
        let sigBitString = derBitString(signature)

        let cert = derSequence(tag: 0x30, value: Data(tbsCert) + Data(sigAlg) + Data(sigBitString))
        return Data(cert)
    }

    // MARK: - ASN.1 Helpers

    private func buildTBSCertificate(serialNumber: [UInt8],
                                      issuer: Data,
                                      subject: Data,
                                      validity: [UInt8],
                                      publicKeyData: [UInt8],
                                      extensions: [UInt8]) -> [UInt8] {
        // version: v3 [0] EXPLICIT INTEGER 2
        let version: [UInt8] = [0xA0, 0x03, 0x02, 0x01, 0x02]
        let serial = derInteger(serialNumber)
        let alg = buildECDSAWithSHA256AlgId()

        var tbs: [UInt8] = version + serial + alg
        tbs += [UInt8](issuer)
        tbs += validity
        tbs += [UInt8](subject)
        tbs += publicKeyData
        tbs += extensions

        return derSequence(tag: 0x30, value: Data(tbs))
    }

    private func buildDNSequence(cn: String, o: String, c: String) -> [UInt8] {
        let cnAttr = buildRDN(oid: oidCommonName, value: cn)
        let oAttr = buildRDN(oid: oidOrganization, value: o)
        let cAttr = buildRDN(oid: oidCountry, value: c)
        return derSequence(tag: 0x30, value: Data(cAttr + oAttr + cnAttr))
    }

    private func buildRDN(oid: [UInt8], value: String) -> [UInt8] {
        let oidEncoded = derOID(oid)
        let utf8Str = derUTF8String(value)
        let atv = derSequence(tag: 0x30, value: Data(oidEncoded + utf8Str))
        return derSet(value: Data(atv))
    }

    private func buildValidity(notBefore: Date, notAfter: Date) -> [UInt8] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        formatter.timeZone = TimeZone(abbreviation: "UTC")
        let nb = derUTCTime(formatter.string(from: notBefore))
        let na = derUTCTime(formatter.string(from: notAfter))
        return derSequence(tag: 0x30, value: Data(nb + na))
    }

    private func buildBasicConstraintsExt(isCA: Bool) -> [UInt8] {
        // OID: 2.5.29.19
        let oid = derOID([0x55, 0x1D, 0x13])
        let caFlag: [UInt8] = isCA ? [0x30, 0x03, 0x01, 0x01, 0xFF] : [0x30, 0x00]
        let octetString = derOctetString(Data(caFlag))
        // Critical = TRUE
        let critical: [UInt8] = [0x01, 0x01, 0xFF]
        return derSequence(tag: 0x30, value: Data(oid + critical + octetString))
    }

    private func buildKeyUsageExt(bits: UInt8) -> [UInt8] {
        // OID: 2.5.29.15
        let oid = derOID([0x55, 0x1D, 0x0F])
        let bitString: [UInt8] = [0x03, 0x02, 0x00, bits]
        let octetString = derOctetString(Data(bitString))
        let critical: [UInt8] = [0x01, 0x01, 0xFF]
        return derSequence(tag: 0x30, value: Data(oid + critical + octetString))
    }

    private func buildSANExt(hostname: String) -> [UInt8] {
        // OID: 2.5.29.17
        let oid = derOID([0x55, 0x1D, 0x11])

        // Check if IP address
        var sanEntry: [UInt8]
        if isIPAddress(hostname) {
            let ipBytes = hostname.split(separator: ".").compactMap { UInt8($0) }
            sanEntry = [0x87, UInt8(ipBytes.count)] + ipBytes
        } else {
            // dNSName [2] IA5String
            let nameBytes = Array(hostname.utf8)
            sanEntry = [0x82, UInt8(nameBytes.count)] + nameBytes
        }

        let generalNames = derSequence(tag: 0x30, value: Data(sanEntry))
        let octetString = derOctetString(Data(generalNames))
        return derSequence(tag: 0x30, value: Data(oid + octetString))
    }

    private func buildExtKeyUsageExt() -> [UInt8] {
        // OID: 2.5.29.37
        let oid = derOID([0x55, 0x1D, 0x25])
        // serverAuth: 1.3.6.1.5.5.7.3.1
        let serverAuth = derOID([0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01])
        let ekuSeq = derSequence(tag: 0x30, value: Data(serverAuth))
        let octetString = derOctetString(Data(ekuSeq))
        return derSequence(tag: 0x30, value: Data(oid + octetString))
    }

    private func buildECDSAWithSHA256AlgId() -> [UInt8] {
        // OID: 1.2.840.10045.4.3.2 (ecdsa-with-SHA256)
        let oid = derOID([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
        return derSequence(tag: 0x30, value: Data(oid))
    }

    private func extractPublicKeyDER(from key: SecKey) -> [UInt8]? {
        var error: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(key, &error) as Data? else { return nil }

        // EC public key: OID sequence + bit string
        // OID for ecPublicKey: 1.2.840.10045.2.1
        let ecOID = derOID([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])
        // Curve OID for P-256: 1.2.840.10045.3.1.7
        let curveOID = derOID([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
        let algSeq = derSequence(tag: 0x30, value: Data(ecOID + curveOID))
        let bitStr = derBitString(keyData)
        return derSequence(tag: 0x30, value: Data(algSeq + bitStr))
    }

    private func extractSubjectDER(from cert: SecCertificate) -> [UInt8]? {
        // Use SecCertificateCopyNormalizedSubjectSequence
        if let subjectData = SecCertificateCopyNormalizedSubjectSequence(cert) {
            return [UInt8](subjectData as Data)
        }
        return nil
    }

    private func signData(_ data: Data, with key: SecKey) -> Data? {
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(key,
                                               .ecdsaSignatureMessageX962SHA256,
                                               data as CFData,
                                               &error) else {
            print("[CA] Sign error: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
            return nil
        }
        return sig as Data
    }

    private func isIPAddress(_ str: String) -> Bool {
        let parts = str.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    // MARK: - DER Encoding Primitives

    private func derLength(_ len: Int) -> [UInt8] {
        if len < 0x80 {
            return [UInt8(len)]
        } else if len < 0x100 {
            return [0x81, UInt8(len)]
        } else {
            return [0x82, UInt8(len >> 8), UInt8(len & 0xFF)]
        }
    }

    private func derSequence(tag: UInt8, value: Data) -> [UInt8] {
        [tag] + derLength(value.count) + [UInt8](value)
    }

    private func derSet(value: Data) -> [UInt8] {
        [0x31] + derLength(value.count) + [UInt8](value)
    }

    private func derInteger(_ bytes: [UInt8]) -> [UInt8] {
        var b = bytes
        // Ensure positive (prepend 0x00 if high bit set)
        if let first = b.first, first >= 0x80 {
            b = [0x00] + b
        }
        return [0x02] + derLength(b.count) + b
    }

    private func derBitString(_ data: Data) -> [UInt8] {
        // Prepend unused bits count (0)
        let content = [UInt8(0)] + [UInt8](data)
        return [0x03] + derLength(content.count) + content
    }

    private func derOctetString(_ data: Data) -> [UInt8] {
        [0x04] + derLength(data.count) + [UInt8](data)
    }

    private func derUTF8String(_ str: String) -> [UInt8] {
        let bytes = Array(str.utf8)
        return [0x0C] + derLength(bytes.count) + bytes
    }

    private func derUTCTime(_ str: String) -> [UInt8] {
        let bytes = Array(str.utf8)
        return [0x17] + derLength(bytes.count) + bytes
    }

    private func derOID(_ bytes: [UInt8]) -> [UInt8] {
        [0x06] + derLength(bytes.count) + bytes
    }

    // OID constants (last arc encoded)
    private var oidCommonName: [UInt8] { [0x55, 0x04, 0x03] }
    private var oidOrganization: [UInt8] { [0x55, 0x04, 0x0A] }
    private var oidCountry: [UInt8] { [0x55, 0x04, 0x06] }
}
