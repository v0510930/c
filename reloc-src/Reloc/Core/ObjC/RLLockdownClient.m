#import "RLLockdownClient.h"
#import "RLASN1DER.h"
#import <arpa/inet.h>

static const uint32_t kRLMaxPlistPacketSize = 4 * 1024 * 1024;
static NSString *const kRLLockdownLabel = @"Reloc";

static NSError *RLLockdownErr(RLErrorCode code, NSString *message) {
    return [NSError errorWithDomain:RLErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation RLLockdownClient {
    RLTLSSocket *_socket;
    RLPairingRecord *_pairingRecord;
    NSArray *_sslCertificates;
    RLLockdownEventBlock _logHandler;
}

- (void)emit:(NSString *)event details:(NSDictionary<NSString *, id> *)details {
    if (_logHandler) {
        _logHandler(event, details ?: @{});
    }
}

- (nullable instancetype)initConnectedToHost:(NSString *)host
                                        port:(uint16_t)port
                               pairingRecord:(RLPairingRecord *)pairingRecord
                                     timeout:(NSTimeInterval)timeout
                                  logHandler:(nullable RLLockdownEventBlock)logHandler
                                       error:(NSError * _Nullable * _Nullable)error {
    self = [super init];
    if (!self) return nil;

    _host = [host copy];
    _port = port;
    _pairingRecord = pairingRecord;
    _logHandler = [logHandler copy];

    _sslCertificates = [pairingRecord copySSLCertificateArrayWithError:error];
    if (!_sslCertificates) {
        return nil;
    }

    _socket = [[RLTLSSocket alloc] initConnectedToHost:host port:port timeout:timeout error:error];
    if (!_socket) {
        return nil;
    }
    [self emit:@"lockdown_connected" details:@{@"host": host, @"port": @(port)}];

    // 1. QueryType sanity handshake
    NSDictionary *qtResp = [self sendPlistRequest:@{
        @"Label": kRLLockdownLabel,
        @"Request": @"QueryType",
    } timeout:timeout error:error];
    if (!qtResp) {
        [_socket close];
        return nil;
    }
    NSString *lockdownType = [qtResp[@"Type"] isKindOfClass:[NSString class]] ? qtResp[@"Type"] : @"";
    if (![lockdownType isEqualToString:@"com.apple.mobile.lockdown"]) {
        [_socket close];
        if (error) {
            *error = RLLockdownErr(RLErrorLockdownProtocol,
                                   [NSString stringWithFormat:@"Unexpected lockdown QueryType: %@", lockdownType]);
        }
        return nil;
    }

    // 2. StartSession
    NSDictionary *startSessionReq = @{
        @"Label": kRLLockdownLabel,
        @"Request": @"StartSession",
        @"HostID": pairingRecord.hostID,
        @"SystemBUID": pairingRecord.systemBUID,
    };
    NSDictionary *sessionResp = [self sendPlistRequest:startSessionReq timeout:timeout error:error];
    if (!sessionResp) {
        [_socket close];
        return nil;
    }
    if (sessionResp[@"Error"]) {
        [_socket close];
        if (error) {
            *error = RLLockdownErr(RLErrorLockdownRejected,
                                   [NSString stringWithFormat:@"lockdownd StartSession rejected: %@", sessionResp[@"Error"]]);
        }
        return nil;
    }

    _sessionID = [sessionResp[@"SessionID"] isKindOfClass:[NSString class]] ? [sessionResp[@"SessionID"] copy] : nil;
    BOOL enableSSL = [sessionResp[@"EnableSessionSSL"] isKindOfClass:[NSNumber class]]
        ? [sessionResp[@"EnableSessionSSL"] boolValue]
        : NO;

    [self emit:@"lockdown_session_started" details:@{@"ssl": @(enableSSL)}];

    // 3. Upgrade lockdownd control socket to TLS (STARTTLS)
    if (enableSSL) {
        if (![_socket upgradeToTLSWithCertificates:_sslCertificates timeout:timeout error:error]) {
            [_socket close];
            return nil;
        }
        [self emit:@"lockdown_tls_upgraded" details:@{}];
    }

    return self;
}

- (nullable RLTLSSocket *)startService:(NSString *)serviceName
                               timeout:(NSTimeInterval)timeout
                                 error:(NSError * _Nullable * _Nullable)error {
    NSMutableDictionary *req = [@{
        @"Label": kRLLockdownLabel,
        @"Request": @"StartService",
        @"Service": serviceName,
    } mutableCopy];
    if (_pairingRecord.escrowBag.length > 0) {
        req[@"EscrowBag"] = _pairingRecord.escrowBag;
    }

    NSDictionary *resp = [self sendPlistRequest:req timeout:timeout error:error];
    if (!resp) {
        return nil;
    }
    if (resp[@"Error"]) {
        if (error) {
            *error = RLLockdownErr(RLErrorLockdownRejected,
                                   [NSString stringWithFormat:@"StartService(%@) rejected: %@",
                                    serviceName, resp[@"Error"]]);
        }
        return nil;
    }

    NSNumber *portNum = [resp[@"Port"] isKindOfClass:[NSNumber class]] ? resp[@"Port"] : nil;
    if (!portNum || portNum.intValue <= 0 || portNum.intValue > 65535) {
        if (error) {
            *error = RLLockdownErr(RLErrorLockdownProtocol, @"StartService response missing valid Port");
        }
        return nil;
    }

    uint16_t servicePort = (uint16_t)portNum.unsignedShortValue;
    BOOL enableServiceSSL = [resp[@"EnableServiceSSL"] isKindOfClass:[NSNumber class]]
        ? [resp[@"EnableServiceSSL"] boolValue]
        : NO;

    [self emit:@"lockdown_service_started"
       details:@{@"service": serviceName, @"port": @(servicePort), @"ssl": @(enableServiceSSL)}];

    RLTLSSocket *serviceSocket = [[RLTLSSocket alloc] initConnectedToHost:self.host
                                                                     port:servicePort
                                                                  timeout:timeout
                                                                    error:error];
    if (!serviceSocket) {
        return nil;
    }

    if (enableServiceSSL) {
        if (![serviceSocket upgradeToTLSWithCertificates:_sslCertificates timeout:timeout error:error]) {
            [serviceSocket close];
            return nil;
        }
        [self emit:@"lockdown_service_tls_upgraded" details:@{@"service": serviceName}];
    }

    return serviceSocket;
}

- (nullable NSDictionary *)sendPlistRequest:(NSDictionary *)request
                                    timeout:(NSTimeInterval)timeout
                                      error:(NSError * _Nullable * _Nullable)error {
    NSError *serErr = nil;
    NSData *xmlData = [NSPropertyListSerialization dataWithPropertyList:request
                                                                 format:NSPropertyListXMLFormat_v1_0
                                                                options:0
                                                                  error:&serErr];
    if (!xmlData) {
        if (error) *error = serErr ?: RLLockdownErr(RLErrorLockdownProtocol, @"Failed to serialize lockdown plist");
        return nil;
    }

    uint32_t netLen = htonl((uint32_t)xmlData.length);
    NSMutableData *framed = [NSMutableData dataWithCapacity:4 + xmlData.length];
    [framed appendBytes:&netLen length:4];
    [framed appendData:xmlData];

    if (![_socket writeData:framed timeout:timeout error:error]) {
        return nil;
    }

    BOOL timedOut = NO;
    NSData *lenHeader = [_socket readExactLength:4 timeout:timeout timedOut:&timedOut error:error];
    if (!lenHeader) {
        if (timedOut && error) {
            *error = RLLockdownErr(RLErrorSocketTimeout, @"Timed out waiting for lockdown response header");
        }
        return nil;
    }

    uint32_t rawLen = 0;
    [lenHeader getBytes:&rawLen length:4];
    uint32_t payloadLen = ntohl(rawLen);
    if (payloadLen == 0 || payloadLen > kRLMaxPlistPacketSize) {
        if (error) {
            *error = RLLockdownErr(RLErrorLockdownProtocol,
                                   [NSString stringWithFormat:@"Invalid lockdown response length: %u", payloadLen]);
        }
        return nil;
    }

    NSData *payload = [_socket readExactLength:payloadLen timeout:timeout timedOut:&timedOut error:error];
    if (!payload) {
        if (timedOut && error) {
            *error = RLLockdownErr(RLErrorSocketTimeout, @"Timed out waiting for lockdown response payload");
        }
        return nil;
    }

    id parsed = [NSPropertyListSerialization propertyListWithData:payload
                                                          options:NSPropertyListImmutable
                                                           format:NULL
                                                            error:&serErr];
    if (![parsed isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = serErr ?: RLLockdownErr(RLErrorLockdownProtocol, @"Lockdown response is not a plist dictionary");
        }
        return nil;
    }
    return (NSDictionary *)parsed;
}

- (void)close {
    if (_socket && !_socket.isClosed && _sessionID.length > 0) {
        NSDictionary *stopReq = @{
            @"Label": kRLLockdownLabel,
            @"Request": @"StopSession",
            @"SessionID": _sessionID,
        };
        (void)[self sendPlistRequest:stopReq timeout:1.0 error:nil];
    }
    _sessionID = nil;
    [_socket close];
}

- (void)dealloc {
    [_socket close];
}

@end
