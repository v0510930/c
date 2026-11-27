#import "RLIAP2Wire.h"
#import "RLASN1DER.h"

static NSError *RLIAP2Err(NSString *message) {
    return [NSError errorWithDomain:RLErrorDomain
                               code:RLErrorIAP2Protocol
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static uint8_t RLAdditiveChecksum(const uint8_t *bytes, NSUInteger length) {
    uint32_t sum = 0;
    for (NSUInteger i = 0; i < length; i++) {
        sum += bytes[i];
    }
    return (uint8_t)((256 - (sum & 0xFF)) & 0xFF);
}

static BOOL RLVerifyZeroSum(const uint8_t *bytes, NSUInteger length) {
    uint32_t sum = 0;
    for (NSUInteger i = 0; i < length; i++) {
        sum += bytes[i];
    }
    return (sum & 0xFF) == 0;
}

@implementation RLIAP2Packet

- (instancetype)initWithFlags:(uint8_t)flags
                     sequence:(uint8_t)sequence
              acknowledgement:(uint8_t)acknowledgement
                      session:(uint8_t)session
                      payload:(nullable NSData *)payload {
    self = [super init];
    if (!self) return nil;
    _flags = flags;
    _sequence = sequence;
    _acknowledgement = acknowledgement;
    _session = session;
    _payload = payload ? [payload copy] : [NSData data];
    return self;
}

- (NSData *)encode {
    BOOL hasPayload = self.payload.length > 0;
    uint16_t totalSize = (uint16_t)(9 + self.payload.length + (hasPayload ? 1 : 0));

    uint8_t header[9];
    header[0] = 0xFF;
    header[1] = 0x5A;
    header[2] = (uint8_t)(totalSize >> 8);
    header[3] = (uint8_t)(totalSize & 0xFF);
    header[4] = self.flags;
    header[5] = self.sequence;
    header[6] = self.acknowledgement;
    header[7] = self.session;
    header[8] = RLAdditiveChecksum(header, 8);

    NSMutableData *frame = [NSMutableData dataWithCapacity:totalSize];
    [frame appendBytes:header length:9];
    if (hasPayload) {
        [frame appendData:self.payload];
        uint8_t payloadChecksum = RLAdditiveChecksum(self.payload.bytes, self.payload.length);
        [frame appendBytes:&payloadChecksum length:1];
    }
    return [frame copy];
}

+ (uint16_t)validateHeaderData:(NSData *)header9
                         error:(NSError * _Nullable * _Nullable)error {
    if (header9.length != 9) {
        if (error) *error = RLIAP2Err(@"Truncated link header");
        return 0;
    }
    const uint8_t *b = header9.bytes;
    uint16_t size = (uint16_t)(((uint16_t)b[2] << 8) | b[3]);
    if (b[0] != 0xFF || b[1] != 0x5A || !RLVerifyZeroSum(b, 9) || size < 9 || size > 4096 || size == 10) {
        if (error) *error = RLIAP2Err(@"Malformed or oversized incoming iAP2 packet header");
        return 0;
    }
    return size;
}

+ (nullable instancetype)decodeFromData:(NSData *)raw
                                  error:(NSError * _Nullable * _Nullable)error {
    if (raw.length < 9) {
        if (error) *error = RLIAP2Err(@"Bad link marker or truncated header");
        return nil;
    }
    const uint8_t *b = raw.bytes;
    if (b[0] != 0xFF || b[1] != 0x5A) {
        if (error) *error = RLIAP2Err(@"Bad link marker");
        return nil;
    }
    uint16_t size = (uint16_t)(((uint16_t)b[2] << 8) | b[3]);
    if (size != raw.length || !RLVerifyZeroSum(b, 9)) {
        if (error) *error = RLIAP2Err(@"Bad link length or header checksum");
        return nil;
    }
    if (raw.length == 10 || (raw.length > 9 && !RLVerifyZeroSum(b + 9, raw.length - 9))) {
        if (error) *error = RLIAP2Err(@"Bad link payload or checksum");
        return nil;
    }

    NSData *payload = raw.length > 9
        ? [raw subdataWithRange:NSMakeRange(9, raw.length - 10)]
        : [NSData data];

    return [[RLIAP2Packet alloc] initWithFlags:b[4]
                                      sequence:b[5]
                               acknowledgement:b[6]
                                       session:b[7]
                                       payload:payload];
}

@end

@implementation RLIAP2Parameter

- (instancetype)initWithIdentifier:(uint16_t)identifier data:(NSData *)data {
    self = [super init];
    if (!self) return nil;
    _identifier = identifier;
    _data = [data copy];
    return self;
}

+ (NSData *)encodeParameter:(uint16_t)identifier data:(nullable NSData *)data {
    NSUInteger len = data.length;
    uint16_t totalSize = (uint16_t)(len + 4);
    uint8_t header[4] = {
        (uint8_t)(totalSize >> 8),
        (uint8_t)(totalSize & 0xFF),
        (uint8_t)(identifier >> 8),
        (uint8_t)(identifier & 0xFF),
    };
    NSMutableData *out = [NSMutableData dataWithCapacity:totalSize];
    [out appendBytes:header length:4];
    if (len > 0) {
        [out appendData:data];
    }
    return [out copy];
}

+ (nullable NSData *)encodeTextParameter:(uint16_t)identifier
                                  string:(NSString *)value
                                   error:(NSError * _Nullable * _Nullable)error {
    if ([value rangeOfString:@"\0"].location != NSNotFound) {
        if (error) *error = RLIAP2Err(@"Embedded NUL in protocol string");
        return nil;
    }
    NSData *utf8 = [value dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *nulTerminated = [NSMutableData dataWithCapacity:utf8.length + 1];
    [nulTerminated appendData:utf8];
    uint8_t nul = 0;
    [nulTerminated appendBytes:&nul length:1];
    return [self encodeParameter:identifier data:nulTerminated];
}

+ (nullable NSArray<RLIAP2Parameter *> *)parseParametersFromData:(NSData *)raw
                                                           error:(NSError * _Nullable * _Nullable)error {
    NSMutableArray<RLIAP2Parameter *> *result = [NSMutableArray array];
    const uint8_t *b = raw.bytes;
    NSUInteger total = raw.length;
    NSUInteger offset = 0;

    while (offset < total) {
        if (total - offset < 4) {
            if (error) *error = RLIAP2Err(@"Truncated iAP2 parameter header");
            return nil;
        }
        uint16_t size = (uint16_t)(((uint16_t)b[offset] << 8) | b[offset + 1]);
        uint16_t identifier = (uint16_t)(((uint16_t)b[offset + 2] << 8) | b[offset + 3]);
        if (size < 4 || offset + size > total) {
            if (error) *error = RLIAP2Err(@"Invalid iAP2 parameter length");
            return nil;
        }
        NSData *value = [raw subdataWithRange:NSMakeRange(offset + 4, size - 4)];
        [result addObject:[[RLIAP2Parameter alloc] initWithIdentifier:identifier data:value]];
        offset += size;
    }
    return [result copy];
}

@end

@implementation RLIAP2Message

- (instancetype)initWithIdentifier:(uint16_t)identifier body:(nullable NSData *)body {
    self = [super init];
    if (!self) return nil;
    _identifier = identifier;
    _body = body ? [body copy] : [NSData data];
    return self;
}

- (NSData *)encode {
    uint16_t totalSize = (uint16_t)(self.body.length + 6);
    uint8_t header[6] = {
        0x40, 0x40,
        (uint8_t)(totalSize >> 8),
        (uint8_t)(totalSize & 0xFF),
        (uint8_t)(self.identifier >> 8),
        (uint8_t)(self.identifier & 0xFF),
    };
    NSMutableData *out = [NSMutableData dataWithCapacity:totalSize];
    [out appendBytes:header length:6];
    if (self.body.length > 0) {
        [out appendData:self.body];
    }
    return [out copy];
}

@end

@implementation RLIAP2MessageBuffer {
    NSMutableData *_buffer;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _buffer = [NSMutableData data];
    return self;
}

- (nullable NSArray<RLIAP2Message *> *)feedData:(NSData *)data
                                          error:(NSError * _Nullable * _Nullable)error {
    if (data.length > 0) {
        [_buffer appendData:data];
    }

    NSMutableArray<RLIAP2Message *> *messages = [NSMutableArray array];
    while (_buffer.length >= 6) {
        const uint8_t *b = _buffer.bytes;
        uint16_t size = (uint16_t)(((uint16_t)b[2] << 8) | b[3]);
        uint16_t identifier = (uint16_t)(((uint16_t)b[4] << 8) | b[5]);
        if (b[0] != 0x40 || b[1] != 0x40 || size < 6) {
            if (error) *error = RLIAP2Err(@"Invalid iAP2 control message header");
            return nil;
        }
        if (_buffer.length < size) {
            break;
        }
        NSData *body = [_buffer subdataWithRange:NSMakeRange(6, size - 6)];
        [messages addObject:[[RLIAP2Message alloc] initWithIdentifier:identifier body:body]];
        [_buffer replaceBytesInRange:NSMakeRange(0, size) withBytes:NULL length:0];
    }

    return [messages copy];
}

@end
