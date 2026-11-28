#import "RLASN1DER.h"

NSErrorDomain const RLErrorDomain = @"com.reloc.core.error";

static NSError *RLMakeError(RLErrorCode code, NSString *description) {
    return [NSError errorWithDomain:RLErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

BOOL RLDERReadElement(const uint8_t *bytes,
                      NSUInteger limit,
                      NSUInteger offset,
                      RLDERElement *outElement,
                      NSError * _Nullable * _Nullable error) {
    if (!bytes || offset > limit || limit - offset < 2) {
        if (error) *error = RLMakeError(RLErrorInvalidASN1, @"Truncated ASN.1 DER element");
        return NO;
    }

    uint8_t tag = bytes[offset];
    uint8_t firstLen = bytes[offset + 1];
    NSUInteger cursor = offset + 2;
    NSUInteger valueLen = 0;

    if ((firstLen & 0x80) == 0) {
        valueLen = firstLen;
    } else {
        uint8_t octets = firstLen & 0x7F;
        if (octets == 0 || octets > 4 || limit - cursor < octets) {
            if (error) *error = RLMakeError(RLErrorInvalidASN1, @"Unsupported or truncated DER length");
            return NO;
        }
        for (uint8_t i = 0; i < octets; i++) {
            valueLen = (valueLen << 8) | bytes[cursor++];
        }
    }

    if (valueLen > limit - cursor) {
        if (error) *error = RLMakeError(RLErrorInvalidASN1, @"DER element exceeds container bounds");
        return NO;
    }

    if (outElement) {
        outElement->tag = tag;
        outElement->headerLength = cursor - offset;
        outElement->valueOffset = cursor;
        outElement->valueLength = valueLen;
        outElement->endOffset = cursor + valueLen;
    }
    return YES;
}

NSArray<NSData *> * _Nullable RLDERExtractPKCS7Certificates(NSData *pkcs7Data,
                                                            NSError * _Nullable * _Nullable error) {
    if (pkcs7Data.length == 0) {
        if (error) *error = RLMakeError(RLErrorInvalidASN1, @"Empty PKCS#7 container");
        return nil;
    }

    const uint8_t *bytes = pkcs7Data.bytes;
    NSUInteger total = pkcs7Data.length;

    // ContentInfo ::= SEQUENCE { contentType OID, content [0] EXPLICIT ANY }
    RLDERElement contentInfo;
    if (!RLDERReadElement(bytes, total, 0, &contentInfo, error) ||
        contentInfo.tag != 0x30 ||
        contentInfo.endOffset != total) {
        if (error && !*error) *error = RLMakeError(RLErrorInvalidASN1, @"Invalid PKCS#7 ContentInfo");
        return nil;
    }

    RLDERElement contentType;
    if (!RLDERReadElement(bytes, contentInfo.endOffset, contentInfo.valueOffset, &contentType, error) ||
        contentType.tag != 0x06) {
        if (error && !*error) *error = RLMakeError(RLErrorInvalidASN1, @"Missing PKCS#7 contentType OID");
        return nil;
    }

    // signedData OID: 1.2.840.113549.1.7.2 -> 2A 86 48 86 F7 0D 01 07 02
    static const uint8_t kSignedDataOID[] = {0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02};
    if (contentType.valueLength != sizeof(kSignedDataOID) ||
        memcmp(bytes + contentType.valueOffset, kSignedDataOID, sizeof(kSignedDataOID)) != 0) {
        if (error) *error = RLMakeError(RLErrorInvalidASN1, @"PKCS#7 container is not SignedData");
        return nil;
    }

    RLDERElement explicitContent;
    if (!RLDERReadElement(bytes, contentInfo.endOffset, contentType.endOffset, &explicitContent, error) ||
        explicitContent.tag != 0xA0) {
        if (error && !*error) *error = RLMakeError(RLErrorInvalidASN1, @"Missing PKCS#7 SignedData wrapper");
        return nil;
    }

    // SignedData ::= SEQUENCE {
    //   version INTEGER,
    //   digestAlgorithms SET,
    //   encapContentInfo SEQUENCE,
    //   certificates [0] IMPLICIT CertificateSet OPTIONAL,
    //   crls [1] IMPLICIT OPTIONAL,
    //   signerInfos SET
    // }
    RLDERElement signedData;
    if (!RLDERReadElement(bytes, explicitContent.endOffset, explicitContent.valueOffset, &signedData, error) ||
        signedData.tag != 0x30) {
        if (error && !*error) *error = RLMakeError(RLErrorInvalidASN1, @"Invalid SignedData sequence");
        return nil;
    }

    NSUInteger cursor = signedData.valueOffset;
    RLDERElement version, digestAlgs, encapContent;
    if (!RLDERReadElement(bytes, signedData.endOffset, cursor, &version, error) || version.tag != 0x02) {
        if (error && !*error) *error = RLMakeError(RLErrorInvalidASN1, @"Missing SignedData version");
        return nil;
    }
    cursor = version.endOffset;

    if (!RLDERReadElement(bytes, signedData.endOffset, cursor, &digestAlgs, error) || digestAlgs.tag != 0x31) {
        if (error && !*error) *error = RLMakeError(RLErrorInvalidASN1, @"Missing SignedData digestAlgorithms");
        return nil;
    }
    cursor = digestAlgs.endOffset;

    if (!RLDERReadElement(bytes, signedData.endOffset, cursor, &encapContent, error) || encapContent.tag != 0x30) {
        if (error && !*error) *error = RLMakeError(RLErrorInvalidASN1, @"Missing SignedData encapContentInfo");
        return nil;
    }
    cursor = encapContent.endOffset;

    NSMutableArray<NSData *> *certs = [NSMutableArray array];
    while (cursor < signedData.endOffset) {
        RLDERElement field;
        if (!RLDERReadElement(bytes, signedData.endOffset, cursor, &field, error)) {
            return nil;
        }
        if (field.tag == 0xA0) {
            NSUInteger certCursor = field.valueOffset;
            while (certCursor < field.endOffset) {
                RLDERElement certEl;
                if (!RLDERReadElement(bytes, field.endOffset, certCursor, &certEl, error)) {
                    return nil;
                }
                if (certEl.tag == 0x30) {
                    NSData *certDER = [NSData dataWithBytes:bytes + certCursor
                                                     length:certEl.endOffset - certCursor];
                    [certs addObject:certDER];
                }
                certCursor = certEl.endOffset;
            }
            break;
        }
        cursor = field.endOffset;
    }

    if (certs.count == 0) {
        if (error) *error = RLMakeError(RLErrorInvalidIdentity, @"PKCS#7 container has no certificates");
        return nil;
    }
    return [certs copy];
}

BOOL RLDERUnwrapPKCS8PrivateKey(NSData *pkcs8Data,
                                NSData * _Nullable * _Nullable outAlgorithmOID,
                                NSData * _Nullable * _Nullable outParameterOID,
                                NSData * _Nullable * _Nullable outInnerKeyData,
                                NSError * _Nullable * _Nullable error) {
    const uint8_t *bytes = pkcs8Data.bytes;
    NSUInteger total = pkcs8Data.length;

    // PrivateKeyInfo ::= SEQUENCE {
    //   version INTEGER (0),
    //   privateKeyAlgorithm SEQUENCE { algorithm OID, parameters ANY OPTIONAL },
    //   privateKey OCTET STRING
    // }
    RLDERElement root;
    if (!RLDERReadElement(bytes, total, 0, &root, error) ||
        root.tag != 0x30 ||
        root.endOffset != total) {
        if (error && !*error) *error = RLMakeError(RLErrorInvalidIdentity, @"Private key must be unencrypted DER PKCS#8");
        return NO;
    }

    RLDERElement version, algSeq, keyOctet;
    if (!RLDERReadElement(bytes, root.endOffset, root.valueOffset, &version, error) || version.tag != 0x02) {
        if (error && !*error) *error = RLMakeError(RLErrorInvalidIdentity, @"Invalid PKCS#8 version");
        return NO;
    }
    if (!RLDERReadElement(bytes, root.endOffset, version.endOffset, &algSeq, error) || algSeq.tag != 0x30) {
        if (error && !*error) *error = RLMakeError(RLErrorInvalidIdentity, @"Invalid PKCS#8 algorithm identifier");
        return NO;
    }
    if (!RLDERReadElement(bytes, root.endOffset, algSeq.endOffset, &keyOctet, error) || keyOctet.tag != 0x04) {
        if (error && !*error) *error = RLMakeError(RLErrorInvalidIdentity, @"Invalid PKCS#8 private key octet string");
        return NO;
    }

    RLDERElement algOID;
    if (!RLDERReadElement(bytes, algSeq.endOffset, algSeq.valueOffset, &algOID, error) || algOID.tag != 0x06) {
        if (error && !*error) *error = RLMakeError(RLErrorInvalidIdentity, @"Missing PKCS#8 algorithm OID");
        return NO;
    }

    NSData *paramOIDData = nil;
    if (algOID.endOffset < algSeq.endOffset) {
        RLDERElement paramEl;
        if (!RLDERReadElement(bytes, algSeq.endOffset, algOID.endOffset, &paramEl, error)) {
            return NO;
        }
        if (paramEl.tag == 0x06) {
            paramOIDData = [NSData dataWithBytes:bytes + paramEl.valueOffset length:paramEl.valueLength];
        }
    }

    if (outAlgorithmOID) {
        *outAlgorithmOID = [NSData dataWithBytes:bytes + algOID.valueOffset length:algOID.valueLength];
    }
    if (outParameterOID) {
        *outParameterOID = paramOIDData;
    }
    if (outInnerKeyData) {
        *outInnerKeyData = [NSData dataWithBytes:bytes + keyOctet.valueOffset length:keyOctet.valueLength];
    }
    return YES;
}

NSData * _Nullable RLDERExtractECP256PrivateScalar(NSData *sec1DER,
                                                   NSError * _Nullable * _Nullable error) {
    const uint8_t *bytes = sec1DER.bytes;
    NSUInteger total = sec1DER.length;

    // ECPrivateKey ::= SEQUENCE {
    //   version INTEGER (1),
    //   privateKey OCTET STRING,
    //   parameters [0] EXPLICIT OPTIONAL,
    //   publicKey [1] EXPLICIT OPTIONAL
    // }
    RLDERElement seq;
    if (!RLDERReadElement(bytes, total, 0, &seq, error) || seq.tag != 0x30 || seq.endOffset != total) {
        if (error && !*error) *error = RLMakeError(RLErrorInvalidIdentity, @"Invalid SEC1 ECPrivateKey");
        return nil;
    }

    RLDERElement version, privOctet;
    if (!RLDERReadElement(bytes, seq.endOffset, seq.valueOffset, &version, error) ||
        version.tag != 0x02 ||
        version.valueLength != 1 ||
        bytes[version.valueOffset] != 1) {
        if (error && !*error) *error = RLMakeError(RLErrorInvalidIdentity, @"Unsupported ECPrivateKey version");
        return nil;
    }

    if (!RLDERReadElement(bytes, seq.endOffset, version.endOffset, &privOctet, error) ||
        privOctet.tag != 0x04 ||
        privOctet.valueLength == 0 ||
        privOctet.valueLength > 32) {
        if (error && !*error) *error = RLMakeError(RLErrorInvalidIdentity, @"Invalid P-256 private scalar length");
        return nil;
    }

    uint8_t scalar[32];
    memset(scalar, 0, sizeof(scalar));
    memcpy(scalar + (32 - privOctet.valueLength), bytes + privOctet.valueOffset, privOctet.valueLength);
    return [NSData dataWithBytes:scalar length:sizeof(scalar)];
}

static BOOL RLCopyDERIntegerTo32Bytes(const uint8_t *bytes,
                                      NSUInteger length,
                                      uint8_t out32[32]) {
    while (length > 0 && bytes[0] == 0x00) {
        bytes++;
        length--;
    }
    if (length == 0 || length > 32) {
        return NO;
    }
    memset(out32, 0, 32);
    memcpy(out32 + (32 - length), bytes, length);
    return YES;
}

NSData * _Nullable RLDERDecodeECDSASignatureToRawRS(NSData *derSignature,
                                                    NSError * _Nullable * _Nullable error) {
    const uint8_t *bytes = derSignature.bytes;
    NSUInteger total = derSignature.length;

    RLDERElement seq;
    if (!RLDERReadElement(bytes, total, 0, &seq, error) || seq.tag != 0x30 || seq.endOffset != total) {
        if (error && !*error) *error = RLMakeError(RLErrorSigningFailed, @"Invalid DER ECDSA signature");
        return nil;
    }

    RLDERElement rEl, sEl;
    if (!RLDERReadElement(bytes, seq.endOffset, seq.valueOffset, &rEl, error) || rEl.tag != 0x02) {
        if (error && !*error) *error = RLMakeError(RLErrorSigningFailed, @"Missing ECDSA r integer");
        return nil;
    }
    if (!RLDERReadElement(bytes, seq.endOffset, rEl.endOffset, &sEl, error) ||
        sEl.tag != 0x02 ||
        sEl.endOffset != seq.endOffset) {
        if (error && !*error) *error = RLMakeError(RLErrorSigningFailed, @"Missing ECDSA s integer");
        return nil;
    }

    uint8_t raw[64];
    if (!RLCopyDERIntegerTo32Bytes(bytes + rEl.valueOffset, rEl.valueLength, raw) ||
        !RLCopyDERIntegerTo32Bytes(bytes + sEl.valueOffset, sEl.valueLength, raw + 32)) {
        if (error) *error = RLMakeError(RLErrorSigningFailed, @"ECDSA signature component out of P-256 range");
        return nil;
    }
    return [NSData dataWithBytes:raw length:sizeof(raw)];
}

BOOL RLDERIsCertificateCA(NSData *certificateDER) {
    const uint8_t *bytes = certificateDER.bytes;
    NSUInteger total = certificateDER.length;

    RLDERElement certSeq, tbsSeq;
    if (!RLDERReadElement(bytes, total, 0, &certSeq, nil) || certSeq.tag != 0x30) return NO;
    if (!RLDERReadElement(bytes, certSeq.endOffset, certSeq.valueOffset, &tbsSeq, nil) || tbsSeq.tag != 0x30) return NO;

    // Walk TBSCertificate fields looking for [3] EXPLICIT Extensions
    NSUInteger cursor = tbsSeq.valueOffset;
    while (cursor < tbsSeq.endOffset) {
        RLDERElement field;
        if (!RLDERReadElement(bytes, tbsSeq.endOffset, cursor, &field, nil)) return NO;
        if (field.tag == 0xA3) {
            RLDERElement extSeq;
            if (!RLDERReadElement(bytes, field.endOffset, field.valueOffset, &extSeq, nil) || extSeq.tag != 0x30) {
                return NO;
            }
            // BasicConstraints OID: 2.5.29.19 -> 55 1D 13
            static const uint8_t kBasicConstraintsOID[] = {0x55, 0x1D, 0x13};
            NSUInteger extCursor = extSeq.valueOffset;
            while (extCursor < extSeq.endOffset) {
                RLDERElement ext;
                if (!RLDERReadElement(bytes, extSeq.endOffset, extCursor, &ext, nil) || ext.tag != 0x30) break;
                RLDERElement oid;
                if (RLDERReadElement(bytes, ext.endOffset, ext.valueOffset, &oid, nil) &&
                    oid.tag == 0x06 &&
                    oid.valueLength == sizeof(kBasicConstraintsOID) &&
                    memcmp(bytes + oid.valueOffset, kBasicConstraintsOID, sizeof(kBasicConstraintsOID)) == 0) {
                    NSUInteger valCursor = oid.endOffset;
                    RLDERElement next;
                    if (!RLDERReadElement(bytes, ext.endOffset, valCursor, &next, nil)) return NO;
                    if (next.tag == 0x01) { // optional critical BOOLEAN
                        valCursor = next.endOffset;
                        if (!RLDERReadElement(bytes, ext.endOffset, valCursor, &next, nil)) return NO;
                    }
                    if (next.tag == 0x04) {
                        // OCTET STRING wrapping BasicConstraints ::= SEQUENCE { cA BOOLEAN DEFAULT FALSE, ... }
                        RLDERElement bcSeq;
                        if (RLDERReadElement(bytes, next.endOffset, next.valueOffset, &bcSeq, nil) &&
                            bcSeq.tag == 0x30 &&
                            bcSeq.valueLength > 0) {
                            RLDERElement caBool;
                            if (RLDERReadElement(bytes, bcSeq.endOffset, bcSeq.valueOffset, &caBool, nil) &&
                                caBool.tag == 0x01 &&
                                caBool.valueLength == 1) {
                                return bytes[caBool.valueOffset] != 0x00;
                            }
                        }
                    }
                    return NO;
                }
                extCursor = ext.endOffset;
            }
            return NO;
        }
        cursor = field.endOffset;
    }
    return NO;
}

NSData * _Nullable RLPEMDecodeBlock(NSData *pemData,
                                    NSString * _Nullable * _Nullable outLabel,
                                    NSError * _Nullable * _Nullable error) {
    NSString *text = [[NSString alloc] initWithData:pemData encoding:NSUTF8StringEncoding];
    if (!text) {
        text = [[NSString alloc] initWithData:pemData encoding:NSASCIIStringEncoding];
    }
    if (!text) {
        if (error) *error = RLMakeError(RLErrorInvalidPEM, @"Unable to decode PEM text");
        return nil;
    }

    NSRange beginPrefix = [text rangeOfString:@"-----BEGIN "];
    if (beginPrefix.location == NSNotFound) {
        if (error) *error = RLMakeError(RLErrorInvalidPEM, @"Missing PEM BEGIN header");
        return nil;
    }
    NSUInteger labelStart = NSMaxRange(beginPrefix);
    NSRange beginSuffix = [text rangeOfString:@"-----"
                                      options:0
                                        range:NSMakeRange(labelStart, text.length - labelStart)];
    if (beginSuffix.location == NSNotFound) {
        if (error) *error = RLMakeError(RLErrorInvalidPEM, @"Malformed PEM BEGIN header");
        return nil;
    }

    NSString *label = [text substringWithRange:NSMakeRange(labelStart, beginSuffix.location - labelStart)];
    NSString *endMarker = [NSString stringWithFormat:@"-----END %@-----", label];
    NSUInteger bodyStart = NSMaxRange(beginSuffix);
    NSRange endRange = [text rangeOfString:endMarker
                                   options:0
                                     range:NSMakeRange(bodyStart, text.length - bodyStart)];
    if (endRange.location == NSNotFound) {
        if (error) *error = RLMakeError(RLErrorInvalidPEM, @"Missing PEM END footer");
        return nil;
    }

    NSString *base64Body = [text substringWithRange:NSMakeRange(bodyStart, endRange.location - bodyStart)];
    NSData *der = [[NSData alloc] initWithBase64EncodedString:base64Body
                                                      options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (der.length == 0) {
        if (error) *error = RLMakeError(RLErrorInvalidPEM, @"Invalid Base64 data in PEM block");
        return nil;
    }
    if (outLabel) {
        *outLabel = label;
    }
    return der;
}
