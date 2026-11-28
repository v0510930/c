#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Local byte stream with immediate cancellation and persistent partial-read buffering.
@interface RLStreamSocket : NSObject

@property (nonatomic, assign, readonly, getter=isClosed) BOOL closed;

/// Wraps an already-connected file descriptor (used by the virtual accessory socketpair).
- (instancetype)initWithFileDescriptor:(int)fd NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

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

/// Wakes an idle in-flight read at a clean packet boundary without closing the socket.
- (void)nudge;

/// Thread-safe immediate close; unblocks any in-flight read/write.
- (void)close;

@end

NS_ASSUME_NONNULL_END
