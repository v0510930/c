#import <Foundation/Foundation.h>
#import "RLStreamSocket.h"

NS_ASSUME_NONNULL_BEGIN

/// A software-only CoreAccessories iAP2 endpoint, exposed as the existing socket transport.
/// Requires no pairing record or IP loopback. MFi authentication still runs over iAP2.
@interface RLVirtualAccessoryTransport : NSObject
@property(nonatomic, strong, readonly) RLStreamSocket *socket;
@property(nonatomic, copy, readonly) NSString *connectionUUID;
@property(nonatomic, copy, readonly) NSString *endpointUUID;

- (nullable instancetype)initWithEventHandler:(nullable void (^)(NSString *, NSDictionary<NSString *, id> *))handler
                                       error:(NSError * _Nullable * _Nullable)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
/// Unblocks the socket immediately and removes only this instance's endpoint and connection.
- (void)close;
@end

NS_ASSUME_NONNULL_END
