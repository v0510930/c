#import "RLPairingRecord.h"
#import "RLASN1DER.h"

static NSError *RLPairError(NSString *message) {
    return [NSError errorWithDomain:RLErrorDomain
                               code:RLErrorPairingInvalid
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation RLPairingRecord

- (nullable instancetype)initWithPlistData:(NSData *)plistData
                                     error:(NSError * _Nullable * _Nullable)error {
    self = [super init];
    if (!self) return nil;

    NSError *plistErr = nil;
    id obj = [NSPropertyListSerialization propertyListWithData:plistData
                                                       options:NSPropertyListImmutable
                                                        format:NULL
                                                         error:&plistErr];
    if (![obj isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = plistErr ?: RLPairError(@"Pairing file must be an XML or binary plist dictionary");
        }
        return nil;
    }

    NSDictionary *dict = (NSDictionary *)obj;
    NSString *hostID = [dict[@"HostID"] isKindOfClass:[NSString class]] ? dict[@"HostID"] : nil;
    NSString *systemBUID = [dict[@"SystemBUID"] isKindOfClass:[NSString class]] ? dict[@"SystemBUID"] : nil;
    NSData *hostCert = [dict[@"HostCertificate"] isKindOfClass:[NSData class]] ? dict[@"HostCertificate"] : nil;
    NSData *hostKey = [dict[@"HostPrivateKey"] isKindOfClass:[NSData class]] ? dict[@"HostPrivateKey"] : nil;

    if (hostID.length == 0 || systemBUID.length == 0 || hostCert.length == 0 || hostKey.length == 0) {
        if (error) {
            *error = RLPairError(@"Pairing file missing required HostID, SystemBUID, HostCertificate, or HostPrivateKey");
        }
        return nil;
    }

    _hostID = [hostID copy];
    _systemBUID = [systemBUID copy];
    _hostCertificatePEM = [hostCert copy];
    _hostPrivateKeyPEM = [hostKey copy];
    _rootCertificatePEM = [dict[@"RootCertificate"] isKindOfClass:[NSData class]] ? [dict[@"RootCertificate"] copy] : nil;
    _deviceCertificatePEM = [dict[@"DeviceCertificate"] isKindOfClass:[NSData class]] ? [dict[@"DeviceCertificate"] copy] : nil;
    _escrowBag = [dict[@"EscrowBag"] isKindOfClass:[NSData class]] ? [dict[@"EscrowBag"] copy] : nil;
    _wifiMACAddress = [dict[@"WiFiMACAddress"] isKindOfClass:[NSString class]] ? [dict[@"WiFiMACAddress"] copy] : nil;
    _udid = [dict[@"UDID"] isKindOfClass:[NSString class]] ? [dict[@"UDID"] copy] : nil;

    // Eagerly validate that we can construct the client identity from HostCertificate + HostPrivateKey.
    SecIdentityRef identity = [self copyClientIdentityWithError:error];
    if (!identity) {
        return nil;
    }
    CFRelease(identity);

    return self;
}

- (nullable SecIdentityRef)copyClientIdentityWithError:(NSError * _Nullable * _Nullable)error {
    NSString *certLabel = nil;
    NSData *certDER = RLPEMDecodeBlock(self.hostCertificatePEM, &certLabel, error);
    if (!certDER) return NULL;

    SecCertificateRef cert = SecCertificateCreateWithData(kCFAllocatorDefault, (__bridge CFDataRef)certDER);
    if (!cert) {
        if (error) *error = RLPairError(@"Invalid HostCertificate DER data");
        return NULL;
    }

    NSString *keyLabel = nil;
    NSData *keyDER = RLPEMDecodeBlock(self.hostPrivateKeyPEM, &keyLabel, error);
    if (!keyDER) {
        CFRelease(cert);
        return NULL;
    }

    // Handle PKCS#1 RSA ("RSA PRIVATE KEY"), PKCS#8 ("PRIVATE KEY"), or SEC1 EC ("EC PRIVATE KEY").
    NSData *secKeyData = keyDER;
    CFStringRef keyType = kSecAttrKeyTypeRSA;

    if ([keyLabel isEqualToString:@"PRIVATE KEY"]) {
        NSData *algOID = nil;
        NSData *innerKey = nil;
        if (!RLDERUnwrapPKCS8PrivateKey(keyDER, &algOID, NULL, &innerKey, error)) {
            CFRelease(cert);
            return NULL;
        }
        static const uint8_t kOIDEC[] = {0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01};
        if (algOID.length == sizeof(kOIDEC) && memcmp(algOID.bytes, kOIDEC, sizeof(kOIDEC)) == 0) {
            keyType = kSecAttrKeyTypeECSECPrimeRandom;
            NSData *scalar = RLDERExtractECP256PrivateScalar(innerKey, error);
            SecKeyRef pubKey = SecCertificateCopyKey(cert);
            NSData *pubX963 = pubKey ? CFBridgingRelease(SecKeyCopyExternalRepresentation(pubKey, NULL)) : nil;
            if (pubKey) CFRelease(pubKey);
            if (!scalar || pubX963.length != 65) {
                CFRelease(cert);
                if (error && !*error) *error = RLPairError(@"Unsupported EC HostPrivateKey format");
                return NULL;
            }
            NSMutableData *combined = [NSMutableData dataWithData:pubX963];
            [combined appendData:scalar];
            secKeyData = combined;
        } else {
            keyType = kSecAttrKeyTypeRSA;
            secKeyData = innerKey;
        }
    } else if ([keyLabel isEqualToString:@"EC PRIVATE KEY"]) {
        keyType = kSecAttrKeyTypeECSECPrimeRandom;
        NSData *scalar = RLDERExtractECP256PrivateScalar(keyDER, error);
        SecKeyRef pubKey = SecCertificateCopyKey(cert);
        NSData *pubX963 = pubKey ? CFBridgingRelease(SecKeyCopyExternalRepresentation(pubKey, NULL)) : nil;
        if (pubKey) CFRelease(pubKey);
        if (!scalar || pubX963.length != 65) {
            CFRelease(cert);
            if (error && !*error) *error = RLPairError(@"Unsupported SEC1 EC HostPrivateKey");
            return NULL;
        }
        NSMutableData *combined = [NSMutableData dataWithData:pubX963];
        [combined appendData:scalar];
        secKeyData = combined;
    }

    NSDictionary *keyAttrs = @{
        (__bridge id)kSecAttrKeyType: (__bridge id)keyType,
        (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPrivate,
    };

    CFErrorRef keyErr = NULL;
    SecKeyRef privKey = SecKeyCreateWithData((__bridge CFDataRef)secKeyData,
                                             (__bridge CFDictionaryRef)keyAttrs,
                                             &keyErr);
    if (!privKey) {
        CFRelease(cert);
        NSError *nsErr = CFBridgingRelease(keyErr);
        if (error) {
            *error = nsErr ?: RLPairError(@"Failed to import HostPrivateKey");
        }
        return NULL;
    }

    SecIdentityRef identity = SecIdentityCreate(kCFAllocatorDefault, cert, privKey);
    CFRelease(privKey);
    CFRelease(cert);

    if (!identity) {
        if (error) {
            *error = RLPairError(@"HostPrivateKey does not match HostCertificate");
        }
        return NULL;
    }

    return identity;
}

- (nullable NSArray *)copySSLCertificateArrayWithError:(NSError * _Nullable * _Nullable)error {
    SecIdentityRef identity = [self copyClientIdentityWithError:error];
    if (!identity) return nil;

    NSMutableArray *result = [NSMutableArray arrayWithObject:(__bridge_transfer id)identity];

    if (self.rootCertificatePEM.length > 0) {
        NSData *rootDER = RLPEMDecodeBlock(self.rootCertificatePEM, NULL, NULL);
        if (rootDER.length > 0) {
            SecCertificateRef rootCert = SecCertificateCreateWithData(kCFAllocatorDefault, (__bridge CFDataRef)rootDER);
            if (rootCert) {
                [result addObject:(__bridge_transfer id)rootCert];
            }
        }
    }

    return [result copy];
}

@end
