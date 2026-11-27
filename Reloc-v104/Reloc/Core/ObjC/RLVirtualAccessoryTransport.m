#import "RLVirtualAccessoryTransport.h"
#import <dlfcn.h>
#import <errno.h>
#import <objc/message.h>
#import <stdatomic.h>
#import <sys/socket.h>
#import <unistd.h>

@protocol RLACCTransportClient
- (NSString *)createConnectionWithType:(int)type andIdentifier:(NSString *)identifier;
- (NSString *)createEndpointWithTransportType:(int)type andProtocol:(int)protocol
                               andIdentifier:(NSString *)identifier
                           andDataOutHandler:(void (^)(NSString *, NSString *, NSData *))handler
                       forConnectionWithUUID:(NSString *)connection publishConnection:(BOOL)publish;
- (BOOL)publishConnectionWithUUID:(NSString *)connection;
- (BOOL)processIncomingData:(NSData *)data forEndpointWithUUID:(NSString *)endpoint;
- (BOOL)destroyEndpointWithUUID:(NSString *)endpoint;
- (BOOL)destroyConnectionWithUUID:(NSString *)connection;
@end

static dispatch_queue_t RLVirtualAccessoryLifecycleQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("dev.reloc.virtual-accessory.lifecycle", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

@interface RLVirtualAccessoryTransport () {
    id<RLACCTransportClient> _client;
    NSLock *_writeLock;
    atomic_int _bridgeFD;
    atomic_bool _closed;
    dispatch_group_t _pump;
    void (^_eventHandler)(NSString *, NSDictionary *);
}
@end

static NSString *RLVirtualLocalized(NSString *key) {
    NSString *pref = [[NSUserDefaults standardUserDefaults] stringForKey:@"reloc.language"];
    NSString *code = nil;
    if ([pref isEqualToString:@"en"]) {
        code = @"en";
    } else if ([pref isEqualToString:@"zh-Hans"]) {
        code = @"zh-Hans";
    } else {
        NSString *sys = NSBundle.mainBundle.preferredLocalizations.firstObject ?: NSLocale.preferredLanguages.firstObject ?: @"en";
        code = [sys.lowercaseString hasPrefix:@"zh"] ? @"zh-Hans" : @"en";
    }
    NSString *path = [NSBundle.mainBundle pathForResource:code ofType:@"lproj"];
    NSBundle *bundle = path ? [NSBundle bundleWithPath:path] : NSBundle.mainBundle;
    return [bundle localizedStringForKey:key value:nil table:nil];
}

static const NSInteger RLVirtualErrorCodeTransient = 1;
static const NSInteger RLVirtualErrorCodeIncompatible = 2;

static NSError *VirtualErrorWithCode(NSInteger code, NSString *detail) {
    return [NSError errorWithDomain:@"dev.reloc.virtual-accessory" code:code
                          userInfo:@{NSLocalizedDescriptionKey: detail}];
}

static NSError *VirtualError(NSString *detail) {
    return VirtualErrorWithCode(RLVirtualErrorCodeTransient, detail);
}

/// Validate each ABI before making calls into a version-specific private interface.
static BOOL HasSignature(id receiver, NSString *name, NSString *result, NSArray<NSString *> *arguments) {
    NSMethodSignature *signature = [receiver methodSignatureForSelector:NSSelectorFromString(name)];
    if (!signature || strcmp(signature.methodReturnType, result.UTF8String) ||
        signature.numberOfArguments != arguments.count + 2) return NO;
    for (NSUInteger i = 0; i < arguments.count; i++) {
        if (strcmp([signature getArgumentTypeAtIndex:i + 2], arguments[i].UTF8String)) return NO;
    }
    return YES;
}

@implementation RLVirtualAccessoryTransport
- (instancetype)initWithEventHandler:(void (^ _Nullable)(NSString *, NSDictionary<NSString *, id> *))handler error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    atomic_init(&_bridgeFD, -1);
    atomic_init(&_closed, false);
    _writeLock = [NSLock new];
    _pump = dispatch_group_create();
    _eventHandler = [handler copy];
    BOOL initialized = NO;
    if (error) *error = nil;
    @try {
        static void *framework;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            framework = dlopen("/System/Library/PrivateFrameworks/CoreAccessories.framework/CoreAccessories", RTLD_NOW | RTLD_LOCAL);
        });
        if (!framework) {
            if (error) *error = VirtualErrorWithCode(RLVirtualErrorCodeIncompatible, RLVirtualLocalized(@"error.virtual.no_framework"));
            return nil;
        }
        Class cls = NSClassFromString(@"ACCTransportClient");
        if (!HasSignature(cls, @"sharedClient", @"@", @[])) {
            if (error) *error = VirtualErrorWithCode(RLVirtualErrorCodeIncompatible, RLVirtualLocalized(@"error.virtual.no_client"));
            return nil;
        }
        _client = ((id (*)(id, SEL))objc_msgSend)(cls, NSSelectorFromString(@"sharedClient"));
        NSArray *signatures = @[
            @[@"createConnectionWithType:andIdentifier:", @"@", @[@"i", @"@"]],
            @[@"createEndpointWithTransportType:andProtocol:andIdentifier:andDataOutHandler:forConnectionWithUUID:publishConnection:",
              @"@", @[@"i", @"i", @"@", @"@?", @"@", @"B"]],
            @[@"publishConnectionWithUUID:", @"B", @[@"@"]],
            @[@"processIncomingData:forEndpointWithUUID:", @"B", @[@"@", @"@"]],
            @[@"destroyEndpointWithUUID:", @"B", @[@"@"]],
            @[@"destroyConnectionWithUUID:", @"B", @[@"@"]],
        ];
        for (NSArray *signature in signatures) {
            if (!HasSignature(_client, signature[0], signature[1], signature[2])) {
                if (error) *error = VirtualErrorWithCode(RLVirtualErrorCodeIncompatible, [NSString stringWithFormat:RLVirtualLocalized(@"error.virtual.incompatible_abi"), signature[0]]);
                return nil;
            }
        }
        int pair[2];
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) {
            if (error) *error = VirtualError([NSString stringWithFormat:RLVirtualLocalized(@"error.virtual.socketpair"), strerror(errno)]);
            return nil;
        }
        _socket = [[RLStreamSocket alloc] initWithFileDescriptor:pair[0]];
        atomic_store(&_bridgeFD, pair[1]);
        int noSigPipe = 1;
        int sockBufSize = 65536;
        struct timeval timeout = {.tv_sec = 1, .tv_usec = 500000};
        setsockopt(pair[1], SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
        setsockopt(pair[1], SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        setsockopt(pair[1], SOL_SOCKET, SO_SNDBUF, &sockBufSize, sizeof(sockBufSize));
        setsockopt(pair[1], SOL_SOCKET, SO_RCVBUF, &sockBufSize, sizeof(sockBufSize));
        setsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &sockBufSize, sizeof(sockBufSize));
        setsockopt(pair[0], SOL_SOCKET, SO_RCVBUF, &sockBufSize, sizeof(sockBufSize));

        NSString *identifier = [@"dev.reloc.virtual." stringByAppendingString:NSUUID.UUID.UUIDString];
        __weak typeof(self) weakSelf = self;
        __block NSError *setupError = nil;
        // Serialize CoreAccessories create/publish strictly behind any previous transport teardown.
        dispatch_sync(RLVirtualAccessoryLifecycleQueue(), ^{
            // Verified against iOS 27.0.1's exported enum string tables:
            // connection 0 = Virtual, transport 5 = Generic, protocol 4 = iAP2.
            self->_connectionUUID = [self->_client createConnectionWithType:0 andIdentifier:identifier];
            if (!self->_connectionUUID) {
                setupError = VirtualError(RLVirtualLocalized(@"error.virtual.create_conn"));
                return;
            }
            self->_endpointUUID = [self->_client createEndpointWithTransportType:5 andProtocol:4 andIdentifier:identifier
                andDataOutHandler:^(NSString *connection, NSString *endpoint, NSData *data) {
                    [weakSelf receiveData:data];
                } forConnectionWithUUID:self->_connectionUUID publishConnection:NO];
            if (!self->_endpointUUID || ![self->_client publishConnectionWithUUID:self->_connectionUUID]) {
                setupError = VirtualError(RLVirtualLocalized(@"error.virtual.create_endpoint"));
                return;
            }
        });
        if (setupError) {
            if (error) *error = setupError;
            return nil;
        }
        [self emit:@"virtual_accessory_published" fields:@{@"connection": _connectionUUID, @"endpoint": _endpointUUID}];
        int pumpFD = pair[1];
        dispatch_group_async(_pump, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            uint8_t bytes[8192];
            for (;;) {
                ssize_t count = recv(pumpFD, bytes, sizeof(bytes), 0);
                if (count < 0 && errno == EINTR) continue;
                if (count <= 0) break;
                @autoreleasepool {
                    RLVirtualAccessoryTransport *transport = weakSelf;
                    if (!transport || ![transport forwardData:[NSData dataWithBytes:bytes length:(NSUInteger)count]]) break;
                }
            }
        });
        const uint8_t detectionBytes[] = {0xff, 0x55, 0x02, 0x00, 0xee, 0x10};
        NSData *detection = [NSData dataWithBytes:detectionBytes length:sizeof(detectionBytes)];
        BOOL detectionConfirmed = NO;
        NSError *lastDetectionError = nil;
        for (int attempt = 1; attempt <= 3; attempt++) {
            lastDetectionError = nil;
            if (![_socket writeData:detection timeout:1.5 error:&lastDetectionError]) {
                break;
            }
            BOOL timedOut = NO;
            NSData *echo = [_socket readExactLength:detection.length timeout:1.2 timedOut:&timedOut error:&lastDetectionError];
            if ([echo isEqualToData:detection]) {
                detectionConfirmed = YES;
                break;
            }
            if (!timedOut && lastDetectionError) {
                break;
            }
        }
        if (!detectionConfirmed) {
            if (error) *error = lastDetectionError ?: VirtualError(RLVirtualLocalized(@"error.virtual.no_detection"));
            return nil;
        }
        [self emit:@"virtual_accessory_detection_confirmed" fields:@{}];
        initialized = YES;
        return self;
    } @catch (NSException *exception) {
        if (error) *error = VirtualError(exception.reason ?: exception.name);
        return nil;
    } @finally {
        // A failed initializer still releases every endpoint and descriptor it acquired.
        // Successful instances retain an open socket until close/dealloc.
        if (!initialized) [self close];
    }
}

- (void)emit:(NSString *)event fields:(NSDictionary *)fields {
    if (_eventHandler) _eventHandler(event, fields);
}

- (BOOL)forwardData:(NSData *)data {
    if (atomic_load(&_closed)) return NO;
    BOOL accepted = [_client processIncomingData:data forEndpointWithUUID:_endpointUUID];
    if (!accepted) {
        [self emit:@"virtual_accessory_input_rejected" fields:@{}];
        [_socket close];
    }
    return accepted;
}

- (void)receiveData:(NSData *)data {
    if (![data isKindOfClass:NSData.class] || data.length == 0) return;
    if (atomic_load(&_closed)) return;
    [_writeLock lock];
    BOOL failed = NO;
    int fd = atomic_load(&_bridgeFD);
    if (!atomic_load(&_closed) && fd >= 0) {
        const uint8_t *bytes = data.bytes;
        NSUInteger offset = 0;
        CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 1.5;
        while (offset < data.length && !atomic_load(&_closed)) {
            ssize_t count = send(fd, bytes + offset, data.length - offset, 0);
            if (count > 0) {
                offset += (NSUInteger)count;
                continue;
            }
            if (count < 0 && errno == EINTR) continue;
            if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                if (CFAbsoluteTimeGetCurrent() < deadline) continue;
            }
            failed = YES;
            break;
        }
    }
    [_writeLock unlock];
    if (failed && !atomic_load(&_closed)) {
        [self emit:@"virtual_accessory_output_failed" fields:@{}];
        [_socket close];
    }
}

- (void)close {
    bool expected = false;
    if (!atomic_compare_exchange_strong(&_closed, &expected, true)) {
        return;
    }
    int fd = atomic_exchange(&_bridgeFD, -1);
    [_socket close];
    if (fd >= 0) shutdown(fd, SHUT_RDWR);

    // Serialize teardown on the shared CoreAccessories lifecycle queue so any subsequent
    // reconnect waits until this endpoint & connection are fully removed and fd is closed.
    id<RLACCTransportClient> client = _client;
    NSString *endpoint = _endpointUUID;
    NSString *connection = _connectionUUID;
    dispatch_group_t pump = _pump;
    NSLock *writeLock = _writeLock;
    void (^handler)(NSString *, NSDictionary *) = _eventHandler;
    dispatch_async(RLVirtualAccessoryLifecycleQueue(), ^{
        dispatch_group_wait(pump, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)));
        // Ensure any in-flight receiveData: write has exited before closing fd.
        [writeLock lock];
        [writeLock unlock];
        @try {
            BOOL endpointRemoved = NO;
            @try {
                endpointRemoved = !endpoint || [client destroyEndpointWithUUID:endpoint];
            } @finally {
                BOOL connectionRemoved = !connection || [client destroyConnectionWithUUID:connection];
                if (handler) handler(@"virtual_accessory_closed", @{@"endpoint_removed": @(endpointRemoved), @"connection_removed": @(connectionRemoved)});
            }
        } @catch (NSException *exception) {
            if (handler) handler(@"virtual_accessory_cleanup_error", @{@"detail": exception.reason ?: exception.name});
        } @finally {
            if (fd >= 0) close(fd);
        }
    });
}

- (void)dealloc { [self close]; }
@end
