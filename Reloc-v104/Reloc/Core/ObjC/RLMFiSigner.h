#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Local MFi-v3 authenticator matching accessory-location's local_mfi_v3_helper contract:
/// - Keeps the complete DER PKCS#7 certificate container verbatim for 0xAA01
/// - Validates an unencrypted DER PKCS#8 P-256 private key matching exactly one non-CA leaf
/// - Signs 32-byte prehashed SHA-256 challenges using ECDSA P-256 and returns raw 64-byte r||s
@interface RLMFiSigner : NSObject

@property (nonatomic, copy, readonly) NSData *certificateContainerData;
@property (nonatomic, copy, readonly) NSString *leafSubjectSummary;
@property (nonatomic, assign, readonly) NSUInteger certificateCount;

- (nullable instancetype)initWithCertificateData:(NSData *)pkcs7Data
                                  privateKeyData:(NSData *)pkcs8Data
                                           error:(NSError * _Nullable * _Nullable)error NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// Signs a 32-byte prehashed MFi-v3 challenge and returns raw 64-byte `r || s`.
- (nullable NSData *)signChallenge:(NSData *)challenge
                             error:(NSError * _Nullable * _Nullable)error;

/// Verifies a raw 64-byte `r || s` signature against the loaded leaf certificate's public key (for self-tests).
- (BOOL)verifyRawSignature:(NSData *)rawRS
              forChallenge:(NSData *)challenge
                     error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
