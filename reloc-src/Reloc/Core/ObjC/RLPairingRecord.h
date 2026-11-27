#import <Foundation/Foundation.h>
#import <Security/Security.h>

NS_ASSUME_NONNULL_BEGIN

/// Represents an iOS lockdownd pairing record (.mobiledevicepairing / .plist).
@interface RLPairingRecord : NSObject

@property (nonatomic, copy, readonly) NSString *hostID;
@property (nonatomic, copy, readonly) NSString *systemBUID;
@property (nonatomic, copy, readonly) NSData *hostCertificatePEM;
@property (nonatomic, copy, readonly) NSData *hostPrivateKeyPEM;
@property (nonatomic, copy, readonly, nullable) NSData *rootCertificatePEM;
@property (nonatomic, copy, readonly, nullable) NSData *deviceCertificatePEM;
@property (nonatomic, copy, readonly, nullable) NSData *escrowBag;
@property (nonatomic, copy, readonly, nullable) NSString *wifiMACAddress;
@property (nonatomic, copy, readonly, nullable) NSString *udid;

- (nullable instancetype)initWithPlistData:(NSData *)plistData
                                     error:(NSError * _Nullable * _Nullable)error NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// Creates a SecIdentityRef from HostCertificate + HostPrivateKey for mutual TLS with lockdownd.
/// Caller is responsible for CFRelease().
- (nullable SecIdentityRef)copyClientIdentityWithError:(NSError * _Nullable * _Nullable)error CF_RETURNS_RETAINED
    NS_SWIFT_NAME(copyClientIdentity());

/// Returns an array suitable for SSLSetCertificate: @[SecIdentityRef, optional RootCertificate].
- (nullable NSArray *)copySSLCertificateArrayWithError:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
