#import "RLTLSSocket.h"
#import "RLASN1DER.h"
#import <Security/Security.h>
#import <Security/SecureTransport.h>
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <netdb.h>
#import <netinet/tcp.h>
#import <poll.h>
#import <stdatomic.h>
#import <sys/socket.h>
#import <unistd.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static NSError *RLSockError(RLErrorCode code, NSString *message) {
    return [NSError errorWithDomain:RLErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@interface RLTLSSocket () {
@package
    int _fd;
    int _wakePipe[2];
    atomic_bool _closedFlag;
    SSLContextRef _sslContext;
    CFAbsoluteTime _ioDeadline;
    NSMutableData *_readBuffer;
}
@end

static int RLPollFD(int fd, int wakeFD, short events, CFAbsoluteTime deadline) {
    while (1) {
        CFAbsoluteTime remaining = deadline - CFAbsoluteTimeGetCurrent();
        if (remaining <= 0) {
            return 0; // timeout
        }
        int timeoutMs = (int)MIN(remaining * 1000.0, 30000.0);
        if (timeoutMs < 1) timeoutMs = 1;

        struct pollfd fds[2];
        fds[0].fd = fd;
        fds[0].events = events;
        fds[0].revents = 0;

        nfds_t nfds = 1;
        if (wakeFD >= 0) {
            fds[1].fd = wakeFD;
            fds[1].events = POLLIN;
            fds[1].revents = 0;
            nfds = 2;
        }

        int rc = poll(fds, nfds, timeoutMs);
        if (rc < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (rc == 0) {
            if (CFAbsoluteTimeGetCurrent() >= deadline) return 0;
            continue;
        }
        if (nfds == 2 && (fds[1].revents & (POLLIN | POLLHUP | POLLERR))) {
            errno = ECANCELED;
            return -2; // cancelled via close
        }
        if (fds[0].revents & (POLLERR | POLLNVAL)) {
            int soErr = 0;
            socklen_t len = sizeof(soErr);
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len);
            errno = soErr ?: EIO;
            return -1;
        }
        return 1;
    }
}

static OSStatus RLSSLReadFunc(SSLConnectionRef connection, void *data, size_t *dataLength) {
    RLTLSSocket *sock = (__bridge RLTLSSocket *)connection;
    size_t requested = *dataLength;
    *dataLength = 0;

    if (atomic_load(&sock->_closedFlag) || sock->_fd < 0) {
        return errSSLClosedAbort;
    }

    uint8_t *buf = (uint8_t *)data;
    size_t totalRead = 0;

    while (totalRead < requested) {
        if (atomic_load(&sock->_closedFlag)) {
            *dataLength = totalRead;
            return errSSLClosedAbort;
        }

        ssize_t n = recv(sock->_fd, buf + totalRead, requested - totalRead, 0);
        if (n > 0) {
            totalRead += (size_t)n;
            continue;
        }
        if (n == 0) {
            *dataLength = totalRead;
            return totalRead > 0 ? errSecSuccess : errSSLClosedGraceful;
        }
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            int ready = RLPollFD(sock->_fd, sock->_wakePipe[0], POLLIN, sock->_ioDeadline);
            if (ready > 0) continue;
            *dataLength = totalRead;
            if (ready == 0) return errSSLWouldBlock;
            return errSSLClosedAbort;
        }
        *dataLength = totalRead;
        return errSSLClosedAbort;
    }

    *dataLength = totalRead;
    return errSecSuccess;
}

static OSStatus RLSSLWriteFunc(SSLConnectionRef connection, const void *data, size_t *dataLength) {
    RLTLSSocket *sock = (__bridge RLTLSSocket *)connection;
    size_t requested = *dataLength;
    *dataLength = 0;

    if (atomic_load(&sock->_closedFlag) || sock->_fd < 0) {
        return errSSLClosedAbort;
    }

    const uint8_t *buf = (const uint8_t *)data;
    size_t totalWritten = 0;

    while (totalWritten < requested) {
        if (atomic_load(&sock->_closedFlag)) {
            *dataLength = totalWritten;
            return errSSLClosedAbort;
        }

        ssize_t n = send(sock->_fd, buf + totalWritten, requested - totalWritten, 0);
        if (n > 0) {
            totalWritten += (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            int ready = RLPollFD(sock->_fd, sock->_wakePipe[0], POLLOUT, sock->_ioDeadline);
            if (ready > 0) continue;
            *dataLength = totalWritten;
            if (ready == 0) return errSSLWouldBlock;
            return errSSLClosedAbort;
        }
        *dataLength = totalWritten;
        return errSSLClosedAbort;
    }

    *dataLength = totalWritten;
    return errSecSuccess;
}

@implementation RLTLSSocket

- (instancetype)initWithFileDescriptor:(int)fd {
    self = [super init];
    if (!self) return nil;

    _fd = fd;
    _wakePipe[0] = -1;
    _wakePipe[1] = -1;
    if (pipe(_wakePipe) == 0) {
        fcntl(_wakePipe[0], F_SETFL, O_NONBLOCK);
        fcntl(_wakePipe[1], F_SETFL, O_NONBLOCK);
    }

    int one = 1;
    setsockopt(_fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    setsockopt(_fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    int flags = fcntl(_fd, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(_fd, F_SETFL, flags | O_NONBLOCK);
    }

    atomic_init(&_closedFlag, false);
    _sslContext = NULL;
    _readBuffer = [NSMutableData data];
    return self;
}

- (nullable instancetype)initConnectedToHost:(NSString *)host
                                        port:(uint16_t)port
                                     timeout:(NSTimeInterval)timeout
                                       error:(NSError * _Nullable * _Nullable)error {
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_family = AF_UNSPEC;

    char portStr[16];
    snprintf(portStr, sizeof(portStr), "%u", (unsigned)port);

    struct addrinfo *res = NULL;
    int gai = getaddrinfo(host.UTF8String, portStr, &hints, &res);
    if (gai != 0 || !res) {
        if (error) {
            *error = RLSockError(RLErrorSocketConnect,
                                 [NSString stringWithFormat:@"Cannot resolve %@:%u (%s)",
                                  host, port, gai_strerror(gai)]);
        }
        return nil;
    }

    int sockfd = -1;
    int lastErrno = ECONNREFUSED;
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + MAX(timeout, 0.5);

    for (struct addrinfo *p = res; p != NULL; p = p->ai_next) {
        int fd = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
        if (fd < 0) {
            lastErrno = errno;
            continue;
        }
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        int flags = fcntl(fd, F_GETFL, 0);
        if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);

        int rc = connect(fd, p->ai_addr, p->ai_addrlen);
        if (rc == 0) {
            sockfd = fd;
            break;
        }
        if (errno == EINPROGRESS) {
            int ready = RLPollFD(fd, -1, POLLOUT, deadline);
            if (ready > 0) {
                int soErr = 0;
                socklen_t len = sizeof(soErr);
                if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len) == 0 && soErr == 0) {
                    sockfd = fd;
                    break;
                }
                lastErrno = soErr ?: ECONNREFUSED;
            } else if (ready == 0) {
                lastErrno = ETIMEDOUT;
            } else {
                lastErrno = errno;
            }
        } else {
            lastErrno = errno;
        }
        close(fd);
    }

    freeaddrinfo(res);

    if (sockfd < 0) {
        if (error) {
            NSString *hint = (lastErrno == ETIMEDOUT || lastErrno == EHOSTUNREACH || lastErrno == ENETUNREACH)
                ? @" (Check that LocalDevVPN / loopback VPN is active)"
                : @"";
            *error = RLSockError(RLErrorSocketConnect,
                                 [NSString stringWithFormat:@"Connect to %@:%u failed: %s%@",
                                  host, port, strerror(lastErrno), hint]);
        }
        return nil;
    }

    return [self initWithFileDescriptor:sockfd];
}

- (void)dealloc {
    [self close];
    if (_sslContext) {
        CFRelease(_sslContext);
        _sslContext = NULL;
    }
    if (_wakePipe[0] >= 0) {
        close(_wakePipe[0]);
        _wakePipe[0] = -1;
    }
    if (_wakePipe[1] >= 0) {
        close(_wakePipe[1]);
        _wakePipe[1] = -1;
    }
}

- (BOOL)isTLSActive {
    return _sslContext != NULL;
}

- (BOOL)isClosed {
    return atomic_load(&_closedFlag);
}

- (BOOL)upgradeToTLSWithCertificates:(NSArray *)certificates
                             timeout:(NSTimeInterval)timeout
                               error:(NSError * _Nullable * _Nullable)error {
    if (self.isClosed) {
        if (error) *error = RLSockError(RLErrorSocketClosed, @"Socket is closed");
        return NO;
    }
    if (_sslContext) {
        return YES;
    }

    SSLContextRef ctx = SSLCreateContext(kCFAllocatorDefault, kSSLClientSide, kSSLStreamType);
    if (!ctx) {
        if (error) *error = RLSockError(RLErrorTLSHandshake, @"Failed to allocate SSLContext");
        return NO;
    }

    OSStatus st = SSLSetIOFuncs(ctx, RLSSLReadFunc, RLSSLWriteFunc);
    if (st == errSecSuccess) st = SSLSetConnection(ctx, (__bridge SSLConnectionRef)self);
    if (st == errSecSuccess) st = SSLSetProtocolVersionMin(ctx, kTLSProtocol12);
    if (st == errSecSuccess) st = SSLSetSessionOption(ctx, kSSLSessionOptionBreakOnServerAuth, true);
    if (st == errSecSuccess && certificates.count > 0) {
        st = SSLSetCertificate(ctx, (__bridge CFArrayRef)certificates);
    }

    if (st != errSecSuccess) {
        CFRelease(ctx);
        if (error) {
            *error = RLSockError(RLErrorTLSHandshake,
                                 [NSString stringWithFormat:@"TLS configuration failed (OSStatus %d)", (int)st]);
        }
        return NO;
    }

    _ioDeadline = CFAbsoluteTimeGetCurrent() + MAX(timeout, 1.0);
    while (1) {
        st = SSLHandshake(ctx);
        if (st == errSecSuccess) {
            break;
        }
        if (st == errSSLServerAuthCompleted) {
            // Peer lockdownd certificate is self-signed by the pairing RootCertificate; proceed.
            continue;
        }
        if (st == errSSLWouldBlock) {
            if (CFAbsoluteTimeGetCurrent() >= _ioDeadline) {
                CFRelease(ctx);
                if (error) *error = RLSockError(RLErrorTLSHandshake, @"TLS handshake timed out");
                return NO;
            }
            continue;
        }
        CFRelease(ctx);
        if (error) {
            *error = RLSockError(RLErrorTLSHandshake,
                                 [NSString stringWithFormat:@"TLS handshake failed (OSStatus %d)", (int)st]);
        }
        return NO;
    }

    _sslContext = ctx;
    return YES;
}

- (BOOL)writeData:(NSData *)data
          timeout:(NSTimeInterval)timeout
            error:(NSError * _Nullable * _Nullable)error {
    if (self.isClosed) {
        if (error) *error = RLSockError(RLErrorSocketClosed, @"Socket is closed");
        return NO;
    }
    if (data.length == 0) return YES;

    _ioDeadline = CFAbsoluteTimeGetCurrent() + MAX(timeout, 0.1);
    const uint8_t *bytes = data.bytes;
    size_t offset = 0;
    size_t total = data.length;

    while (offset < total) {
        if (self.isClosed) {
            if (error) *error = RLSockError(RLErrorSocketClosed, @"Socket closed during write");
            return NO;
        }

        if (_sslContext) {
            size_t processed = 0;
            OSStatus st = SSLWrite(_sslContext, bytes + offset, total - offset, &processed);
            offset += processed;
            if (st == errSecSuccess) continue;
            if (st == errSSLWouldBlock) {
                if (CFAbsoluteTimeGetCurrent() >= _ioDeadline) {
                    if (error) *error = RLSockError(RLErrorSocketTimeout, @"TLS write timed out");
                    return NO;
                }
                continue;
            }
            if (error) {
                *error = RLSockError(RLErrorSocketIO,
                                     [NSString stringWithFormat:@"TLS write failed (OSStatus %d)", (int)st]);
            }
            return NO;
        } else {
            ssize_t n = send(_fd, bytes + offset, total - offset, 0);
            if (n > 0) {
                offset += (size_t)n;
                continue;
            }
            if (n < 0 && errno == EINTR) continue;
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                int ready = RLPollFD(_fd, _wakePipe[0], POLLOUT, _ioDeadline);
                if (ready > 0) continue;
                if (ready == 0) {
                    if (error) *error = RLSockError(RLErrorSocketTimeout, @"Socket write timed out");
                } else {
                    if (error) *error = RLSockError(RLErrorSocketClosed, @"Socket closed during write");
                }
                return NO;
            }
            if (error) {
                *error = RLSockError(RLErrorSocketIO,
                                     [NSString stringWithFormat:@"Socket write failed: %s", strerror(errno)]);
            }
            return NO;
        }
    }
    return YES;
}

- (nullable NSData *)readExactLength:(NSUInteger)length
                             timeout:(NSTimeInterval)timeout
                            timedOut:(BOOL * _Nullable)timedOut
                               error:(NSError * _Nullable * _Nullable)error {
    if (timedOut) *timedOut = NO;
    if (length == 0) return [NSData data];

    if (_readBuffer.length >= length) {
        NSData *slice = [_readBuffer subdataWithRange:NSMakeRange(0, length)];
        [_readBuffer replaceBytesInRange:NSMakeRange(0, length) withBytes:NULL length:0];
        return slice;
    }

    if (self.isClosed) {
        if (error) *error = RLSockError(RLErrorSocketClosed, @"Socket is closed");
        return nil;
    }

    _ioDeadline = CFAbsoluteTimeGetCurrent() + MAX(timeout, 0.001);
    uint8_t scratch[4096];

    while (_readBuffer.length < length) {
        if (self.isClosed) {
            if (error) *error = RLSockError(RLErrorSocketClosed, @"Socket closed during read");
            return nil;
        }

        size_t need = MIN(length - _readBuffer.length, sizeof(scratch));

        if (_sslContext) {
            size_t processed = 0;
            OSStatus st = SSLRead(_sslContext, scratch, need, &processed);
            if (processed > 0) {
                [_readBuffer appendBytes:scratch length:processed];
            }
            if (st == errSecSuccess) continue;
            if (st == errSSLWouldBlock) {
                if (_readBuffer.length >= length) break;
                if (CFAbsoluteTimeGetCurrent() >= _ioDeadline) {
                    if (timedOut) *timedOut = YES;
                    return nil;
                }
                continue;
            }
            if (st == errSSLClosedGraceful || st == errSSLClosedNoNotify) {
                if (error) *error = RLSockError(RLErrorSocketClosed, @"Peer closed TLS stream");
                return nil;
            }
            if (error) {
                *error = RLSockError(RLErrorSocketIO,
                                     [NSString stringWithFormat:@"TLS read failed (OSStatus %d)", (int)st]);
            }
            return nil;
        } else {
            ssize_t n = recv(_fd, scratch, need, 0);
            if (n > 0) {
                [_readBuffer appendBytes:scratch length:(size_t)n];
                continue;
            }
            if (n == 0) {
                if (error) *error = RLSockError(RLErrorSocketClosed, @"Peer closed TCP stream");
                return nil;
            }
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                int ready = RLPollFD(_fd, _wakePipe[0], POLLIN, _ioDeadline);
                if (ready > 0) continue;
                if (ready == 0) {
                    if (timedOut) *timedOut = YES;
                    return nil;
                }
                if (error) *error = RLSockError(RLErrorSocketClosed, @"Socket closed during read");
                return nil;
            }
            if (error) {
                *error = RLSockError(RLErrorSocketIO,
                                     [NSString stringWithFormat:@"Socket read failed: %s", strerror(errno)]);
            }
            return nil;
        }
    }

    NSData *slice = [_readBuffer subdataWithRange:NSMakeRange(0, length)];
    [_readBuffer replaceBytesInRange:NSMakeRange(0, length) withBytes:NULL length:0];
    return slice;
}

- (void)close {
    bool expected = false;
    if (atomic_compare_exchange_strong(&_closedFlag, &expected, true)) {
        if (_wakePipe[1] >= 0) {
            uint8_t byte = 1;
            (void)write(_wakePipe[1], &byte, 1);
        }
        if (_fd >= 0) {
            shutdown(_fd, SHUT_RDWR);
            close(_fd);
            _fd = -1;
        }
    }
}

@end

#pragma clang diagnostic pop
