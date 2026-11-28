#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const RLErrorDomain;

typedef NS_ERROR_ENUM(RLErrorDomain, RLErrorCode) {
    RLErrorInvalidASN1 = 1001,
    RLErrorInvalidPEM = 1002,
    RLErrorInvalidIdentity = 1003,
    RLErrorInvalidChallenge = 1004,
    RLErrorSigningFailed = 1005,
    RLErrorSocketIO = 2002,
    RLErrorSocketTimeout = 2003,
    RLErrorSocketClosed = 2004,
    RLErrorIAP2Protocol = 4001,
};

typedef struct {
    uint8_t tag;
    NSUInteger headerLength;
    NSUInteger valueOffset;
    NSUInteger valueLength;
    NSUInteger endOffset;
} RLDERElement;

/// Reads one DER TLV element starting at `offset` within `[0, limit)`.
BOOL RLDERReadElement(const uint8_t *bytes,
                      NSUInteger limit,
                      NSUInteger offset,
                      RLDERElement *outElement,
                      NSError * _Nullable * _Nullable error);

/// Extracts all X.509 certificate DER blobs from a DER-encoded PKCS#7 SignedData container.
NSArray<NSData *> * _Nullable RLDERExtractPKCS7Certificates(NSData *pkcs7Data,
                                                            NSError * _Nullable * _Nullable error);

/// Unwraps a plaintext DER PKCS#8 PrivateKeyInfo into algorithm OID, optional parameter OID, and inner private key bytes.
BOOL RLDERUnwrapPKCS8PrivateKey(NSData *pkcs8Data,
                                NSData * _Nullable * _Nullable outAlgorithmOID,
                                NSData * _Nullable * _Nullable outParameterOID,
                                NSData * _Nullable * _Nullable outInnerKeyData,
                                NSError * _Nullable * _Nullable error);

/// Extracts the 32-byte big-endian private scalar `d` from a SEC1 ECPrivateKey DER structure.
NSData * _Nullable RLDERExtractECP256PrivateScalar(NSData *sec1DER,
                                                   NSError * _Nullable * _Nullable error);

/// Converts an ASN.1 DER ECDSA signature (`SEQUENCE { INTEGER r, INTEGER s }`) into raw 64-byte `r || s`.
NSData * _Nullable RLDERDecodeECDSASignatureToRawRS(NSData *derSignature,
                                                    NSError * _Nullable * _Nullable error);

/// Returns YES if the DER X.509 certificate has a BasicConstraints extension with cA == TRUE.
BOOL RLDERIsCertificateCA(NSData *certificateDER);

/// Decodes a single PEM block into raw DER bytes and optionally outputs its header label (e.g. "RSA PRIVATE KEY").
NSData * _Nullable RLPEMDecodeBlock(NSData *pemData,
                                    NSString * _Nullable * _Nullable outLabel,
                                    NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
