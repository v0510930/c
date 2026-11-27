#import <Foundation/Foundation.h>
#import "RLPairingRecord.h"
#import "RLTLSSocket.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^RLLockdownEventBlock)(NSString *event, NSDictionary<NSString *, id> *details);

/// Connects to iOS lockdownd over local loopback (default 10.7.0.1:62078),
/// negotiates StartSession + STARTTLS with a pairing record, and spawns lockdown services
/// such as `com.apple.carkit.service`.
@interface RLLockdownClient : NSObject

@property (nonatomic, copy, readonly) NSString *host;
@property (nonatomic, assign, readonly) uint16_t port;
@property (nonatomic, copy, readonly, nullable) NSString *sessionID;

- (nullable instancetype)initConnectedToHost:(NSString *)host
                                        port:(uint16_t)port
                               pairingRecord:(RLPairingRecord *)pairingRecord
                                     timeout:(NSTimeInterval)timeout
                                  logHandler:(nullable RLLockdownEventBlock)logHandler
                                       error:(NSError * _Nullable * _Nullable)error;

- (instancetype)init NS_UNAVAILABLE;

/// Requests `StartService` (e.g. "com.apple.carkit.service") and opens a connected socket
/// to the returned service port (upgrading to TLS if `EnableServiceSSL` is true).
- (nullable RLTLSSocket *)startService:(NSString *)serviceName
                               timeout:(NSTimeInterval)timeout
                                 error:(NSError * _Nullable * _Nullable)error;

/// Sends StopSession (best-effort) and closes the lockdown control socket.
- (void)close;

@end

NS_ASSUME_NONNULL_END
