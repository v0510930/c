#import "RLMFiSigner.h"
#import "RLASN1DER.h"
#import <Security/Security.h>

static const NSUInteger kRLMaxIdentityBytes = 16 * 1024;

// OID 1.2.840.10045.2.1 (id-ecPublicKey)
static const uint8_t kOIDECPublicKey[] = {0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01};
// OID 1.2.840.10045.3.1.7 (prime256v1 / secp256r1)
static const uint8_t kOIDPrime256v1[] = {0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07};

static NSError *RLMFiError(RLErrorCode code, NSString *message) {
    return [NSError errorWithDomain:RLErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSData *RLRawRSToDER(NSData *rawRS) {
    const uint8_t *bytes = rawRS.bytes;

    NSMutableData * (^encodeInt)(const uint8_t *, NSUInteger) = ^NSMutableData *(const uint8_t *src, NSUInteger len) {
        NSUInteger start = 0;
        while (start < len - 1 && src[start] == 0x00) {
            start++;
        }
        NSUInteger trimmedLen = len - start;
        BOOL needsLeadingZero = (src[start] & 0x80) != 0;
        NSMutableData *out = [NSMutableData dataWithCapacity:2 + trimmedLen + (needsLeadingZero ? 1 : 0)];
        uint8_t tag = 0x02;
        uint8_t intLen = (uint8_t)(trimmedLen + (needsLeadingZero ? 1 : 0));
        [out appendBytes:&tag length:1];
        [out appendBytes:&intLen length:1];
        if (needsLeadingZero) {
            uint8_t zero = 0x00;
            [out appendBytes:&zero length:1];
        }
        [out appendBytes:src + start length:trimmedLen];
        return out;
    };

    NSData *rDER = encodeInt(bytes, 32);
    NSData *sDER = encodeInt(bytes + 32, 32);
    NSMutableData *seq = [NSMutableData dataWithCapacity:2 + rDER.length + sDER.length];
    uint8_t seqTag = 0x30;
    uint8_t seqLen = (uint8_t)(rDER.length + sDER.length);
    [seq appendBytes:&seqTag length:1];
    [seq appendBytes:&seqLen length:1];
    [seq appendData:rDER];
    [seq appendData:sDER];
    return seq;
}

@implementation RLMFiSigner {
    SecKeyRef _privateKey;
    SecKeyRef _leafPublicKey;
}

- (void)dealloc {
    if (_privateKey) {
        CFRelease(_privateKey);
        _privateKey = NULL;
    }
    if (_leafPublicKey) {
        CFRelease(_leafPublicKey);
        _leafPublicKey = NULL;
    }
}

- (nullable instancetype)initWithCertificateData:(NSData *)pkcs7Data
                                  privateKeyData:(NSData *)pkcs8Data
                                           error:(NSError * _Nullable * _Nullable)error {
    self = [super init];
    if (!self) return nil;

    if (pkcs7Data.length == 0 || pkcs7Data.length > kRLMaxIdentityBytes ||
        pkcs8Data.length == 0 || pkcs8Data.length > kRLMaxIdentityBytes) {
        if (error) {
            *error = RLMFiError(RLErrorInvalidIdentity, @"Identity files must contain 1..16384 bytes");
        }
        return nil;
    }

    NSArray<NSData *> *certDERs = RLDERExtractPKCS7Certificates(pkcs7Data, error);
    if (!certDERs) {
        return nil;
    }

    NSData *algOID = nil;
    NSData *paramOID = nil;
    NSData *innerKey = nil;
    if (!RLDERUnwrapPKCS8PrivateKey(pkcs8Data, &algOID, &paramOID, &innerKey, error)) {
        return nil;
    }

    if (algOID.length != sizeof(kOIDECPublicKey) ||
        memcmp(algOID.bytes, kOIDECPublicKey, sizeof(kOIDECPublicKey)) != 0 ||
        paramOID.length != sizeof(kOIDPrime256v1) ||
        memcmp(paramOID.bytes, kOIDPrime256v1, sizeof(kOIDPrime256v1)) != 0) {
        if (error) {
            *error = RLMFiError(RLErrorInvalidIdentity, @"Private key must be an EC P-256 (prime256v1) key");
        }
        return nil;
    }

    NSData *scalarD = RLDERExtractECP256PrivateScalar(innerKey, error);
    if (!scalarD) {
        return nil;
    }

    // Match the private scalar against non-CA P-256 leaf certificates inside the PKCS#7 container.
    // On iOS, SecKeyCreateWithData expects ANSI X9.63 private key layout: 04 || X(32) || Y(32) || D(32).
    // We combine each non-CA P-256 leaf's public key (04 || X || Y) with D and cryptographically verify
    // an ECDSA sign+verify round trip to prove D * G == (X, Y).
    uint8_t testDigestBytes[32];
    for (int i = 0; i < 32; i++) testDigestBytes[i] = (uint8_t)(0xA5 ^ i);
    NSData *testDigest = [NSData dataWithBytes:testDigestBytes length:sizeof(testDigestBytes)];

    NSUInteger matchingLeaves = 0;
    SecKeyRef matchedPrivKey = NULL;
    SecKeyRef matchedPubKey = NULL;
    NSString *matchedSubject = @"Unknown Certificate";

    NSDictionary *privAttrs = @{
        (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
        (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPrivate,
        (__bridge id)kSecAttrKeySizeInBits: @256,
    };

    for (NSData *certDER in certDERs) {
        if (RLDERIsCertificateCA(certDER)) {
            continue;
        }
        SecCertificateRef certRef = SecCertificateCreateWithData(kCFAllocatorDefault, (__bridge CFDataRef)certDER);
        if (!certRef) {
            continue;
        }
        SecKeyRef pubKey = SecCertificateCopyKey(certRef);
        if (!pubKey) {
            CFRelease(certRef);
            continue;
        }

        CFErrorRef pubExportErr = NULL;
        NSData *pubX963 = CFBridgingRelease(SecKeyCopyExternalRepresentation(pubKey, &pubExportErr));
        if (pubExportErr) CFRelease(pubExportErr);

        // Uncompressed P-256 point is 65 bytes starting with 0x04
        if (pubX963.length == 65 && ((const uint8_t *)pubX963.bytes)[0] == 0x04) {
            NSMutableData *x963Priv = [NSMutableData dataWithCapacity:97];
            [x963Priv appendData:pubX963];
            [x963Priv appendData:scalarD];

            CFErrorRef keyErr = NULL;
            SecKeyRef candidatePriv = SecKeyCreateWithData((__bridge CFDataRef)x963Priv,
                                                           (__bridge CFDictionaryRef)privAttrs,
                                                           &keyErr);
            if (keyErr) CFRelease(keyErr);

            if (candidatePriv) {
                CFErrorRef signErr = NULL;
                NSData *testSig = CFBridgingRelease(SecKeyCreateSignature(candidatePriv,
                                                                          kSecKeyAlgorithmECDSASignatureDigestX962SHA256,
                                                                          (__bridge CFDataRef)testDigest,
                                                                          &signErr));
                if (signErr) CFRelease(signErr);

                BOOL verified = NO;
                if (testSig) {
                    CFErrorRef verifyErr = NULL;
                    verified = SecKeyVerifySignature(pubKey,
                                                     kSecKeyAlgorithmECDSASignatureDigestX962SHA256,
                                                     (__bridge CFDataRef)testDigest,
                                                     (__bridge CFDataRef)testSig,
                                                     &verifyErr);
                    if (verifyErr) CFRelease(verifyErr);
                }

                if (verified) {
                    matchingLeaves++;
                    if (matchingLeaves == 1) {
                        matchedPrivKey = (SecKeyRef)CFRetain(candidatePriv);
                        matchedPubKey = (SecKeyRef)CFRetain(pubKey);
                        NSString *summary = CFBridgingRelease(SecCertificateCopySubjectSummary(certRef));
                        if (summary.length > 0) {
                            matchedSubject = summary;
                        }
                    }
                }
                CFRelease(candidatePriv);
            }
        }

        CFRelease(pubKey);
        CFRelease(certRef);
    }

    if (matchingLeaves != 1 || !matchedPrivKey || !matchedPubKey) {
        if (matchedPrivKey) CFRelease(matchedPrivKey);
        if (matchedPubKey) CFRelease(matchedPubKey);
        if (error) {
            *error = RLMFiError(RLErrorInvalidIdentity, @"Private key must match exactly one non-CA P-256 leaf certificate");
        }
        return nil;
    }

    _privateKey = matchedPrivKey;
    _leafPublicKey = matchedPubKey;
    _certificateContainerData = [pkcs7Data copy];
    _leafSubjectSummary = [matchedSubject copy];
    _certificateCount = certDERs.count;
    return self;
}

- (nullable NSData *)signChallenge:(NSData *)challenge
                             error:(NSError * _Nullable * _Nullable)error {
    if (challenge.length != 32) {
        if (error) {
            *error = RLMFiError(RLErrorInvalidChallenge, @"MFi-v3 challenge must be exactly 32 bytes (prehashed SHA-256)");
        }
        return nil;
    }

    CFErrorRef cfError = NULL;
    NSData *derSig = CFBridgingRelease(SecKeyCreateSignature(_privateKey,
                                                             kSecKeyAlgorithmECDSASignatureDigestX962SHA256,
                                                             (__bridge CFDataRef)challenge,
                                                             &cfError));
    if (!derSig) {
        NSError *nsErr = CFBridgingRelease(cfError);
        if (error) {
            *error = nsErr ?: RLMFiError(RLErrorSigningFailed, @"ECDSA P-256 prehashed signing failed");
        }
        return nil;
    }

    return RLDERDecodeECDSASignatureToRawRS(derSig, error);
}

- (BOOL)verifyRawSignature:(NSData *)rawRS
              forChallenge:(NSData *)challenge
                     error:(NSError * _Nullable * _Nullable)error {
    if (rawRS.length != 64 || challenge.length != 32) {
        if (error) {
            *error = RLMFiError(RLErrorSigningFailed, @"Expected 64-byte signature and 32-byte digest");
        }
        return NO;
    }

    NSData *derSig = RLRawRSToDER(rawRS);
    CFErrorRef cfError = NULL;
    BOOL ok = SecKeyVerifySignature(_leafPublicKey,
                                    kSecKeyAlgorithmECDSASignatureDigestX962SHA256,
                                    (__bridge CFDataRef)challenge,
                                    (__bridge CFDataRef)derSig,
                                    &cfError);
    if (!ok && cfError) {
        NSError *nsErr = CFBridgingRelease(cfError);
        if (error) *error = nsErr;
    } else if (cfError) {
        CFRelease(cfError);
    }
    return ok;
}

@end
