#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_OPTIONS(uint8_t, RLIAP2LinkFlags) {
    RLIAP2LinkFlagSYN = 0x80,
    RLIAP2LinkFlagACK = 0x40,
    RLIAP2LinkFlagEAK = 0x20,
    RLIAP2LinkFlagRST = 0x10,
};

/// iAP2 link-layer packet (`FF 5A ...`).
@interface RLIAP2Packet : NSObject

@property (nonatomic, assign, readonly) uint8_t flags;
@property (nonatomic, assign, readonly) uint8_t sequence;
@property (nonatomic, assign, readonly) uint8_t acknowledgement;
@property (nonatomic, assign, readonly) uint8_t session;
@property (nonatomic, copy, readonly) NSData *payload;

- (instancetype)initWithFlags:(uint8_t)flags
                     sequence:(uint8_t)sequence
              acknowledgement:(uint8_t)acknowledgement
                      session:(uint8_t)session
                      payload:(nullable NSData *)payload NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

- (NSData *)encode;

+ (nullable instancetype)decodeFromData:(NSData *)raw
                                  error:(NSError * _Nullable * _Nullable)error;

/// Validates a 9-byte link header and returns the total packet length, or 0 on error.
+ (uint16_t)validateHeaderData:(NSData *)header9
                         error:(NSError * _Nullable * _Nullable)error;

@end

/// iAP2 control parameter (2B big-endian length + 2B big-endian id + data).
@interface RLIAP2Parameter : NSObject

@property (nonatomic, assign, readonly) uint16_t identifier;
@property (nonatomic, copy, readonly) NSData *data;

- (instancetype)initWithIdentifier:(uint16_t)identifier data:(NSData *)data;

+ (NSData *)encodeParameter:(uint16_t)identifier data:(nullable NSData *)data
    NS_SWIFT_NAME(encode(_:data:));
+ (nullable NSData *)encodeTextParameter:(uint16_t)identifier
                                  string:(NSString *)value
                                   error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(encodeText(_:string:));
+ (nullable NSArray<RLIAP2Parameter *> *)parseParametersFromData:(NSData *)raw
                                                           error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(parseParameters(from:));

@end

/// iAP2 control message (`40 40` + 2B length + 2B identifier + body).
@interface RLIAP2Message : NSObject

@property (nonatomic, assign, readonly) uint16_t identifier;
@property (nonatomic, copy, readonly) NSData *body;

- (instancetype)initWithIdentifier:(uint16_t)identifier body:(nullable NSData *)body NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (NSData *)encode;

@end

/// Stream reassembler for iAP2 control messages crossing or sharing link packets.
@interface RLIAP2MessageBuffer : NSObject

- (nullable NSArray<RLIAP2Message *> *)feedData:(NSData *)data
                                          error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(feed(_:));

@end

NS_ASSUME_NONNULL_END
