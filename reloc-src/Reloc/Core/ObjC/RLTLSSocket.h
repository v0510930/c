#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// POSIX TCP socket with optional mid-stream TLS upgrade (STARTTLS) via SecureTransport,
/// instant cross-thread cancellation via self-pipe, and persistent partial-read buffering
/// so caller timeouts never discard partially received packets.
@interface RLTLSSocket : NSObject

@property (nonatomic, assign, readonly, getter=isTLSActive) BOOL tlsActive;
@property (nonatomic, assign, readonly, getter=isClosed) BOOL closed;

/// Connects a TCP socket to host:port (e.g. "10.7.0.1", 62078).
- (nullable instancetype)initConnectedToHost:(NSString *)host
                                        port:(uint16_t)port
                                     timeout:(NSTimeInterval)timeout
                                       error:(NSError * _Nullable * _Nullable)error;

/// Wraps an already-connected file descriptor (useful for loopback unit tests).
- (instancetype)initWithFileDescriptor:(int)fd NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// Upgrades the connected TCP stream to mutual TLS using the certificate array
/// (`@[SecIdentityRef, optional SecCertificateRef...]`).
- (BOOL)upgradeToTLSWithCertificates:(NSArray *)certificates
                             timeout:(NSTimeInterval)timeout
                               error:(NSError * _Nullable * _Nullable)error;

/// Writes all bytes in `data` within `timeout` seconds.
- (BOOL)writeData:(NSData *)data
          timeout:(NSTimeInterval)timeout
            error:(NSError * _Nullable * _Nullable)error;

/// Reads exactly `length` bytes within `timeout` seconds.
/// On timeout, sets `*timedOut = YES`, `*error = nil`, returns `nil`, and preserves any
/// partially received bytes in an internal buffer for the next read.
- (nullable NSData *)readExactLength:(NSUInteger)length
                             timeout:(NSTimeInterval)timeout
                            timedOut:(BOOL * _Nullable)timedOut
                               error:(NSError * _Nullable * _Nullable)error;

/// Thread-safe immediate close; unblocks any in-flight read/write/handshake.
- (void)close;

@end

NS_ASSUME_NONNULL_END
