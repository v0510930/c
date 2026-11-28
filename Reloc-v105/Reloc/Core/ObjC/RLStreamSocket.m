#import "RLStreamSocket.h"
#import "RLASN1DER.h"
#import <errno.h>
#import <fcntl.h>
#import <poll.h>
#import <stdatomic.h>
#import <sys/socket.h>
#import <time.h>
#import <unistd.h>

static inline double RLMonotonicNow(void) {
    return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9;
}

static NSError *RLSockError(RLErrorCode code, NSString *message) {
    return [NSError errorWithDomain:RLErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@interface RLStreamSocket () {
@package
    atomic_int _fd;
    int _wakePipe[2];
    atomic_bool _closedFlag;
    atomic_bool _nudgedFlag;
    double _ioDeadline;
    NSMutableData *_readBuffer;
}
@end

static int RLPollFD(int fd, int wakeFD, const atomic_bool *closedFlag, short events, double deadline) {
    while (1) {
        double remaining = deadline - RLMonotonicNow();
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
            if (RLMonotonicNow() >= deadline) return 0;
            continue;
        }
        if (nfds == 2 && (fds[1].revents & (POLLIN | POLLHUP | POLLERR))) {
            if (closedFlag && atomic_load(closedFlag)) {
                errno = ECANCELED;
                return -2; // cancelled via close
            }
            // Drain transient nudge wakeups and wake caller cleanly.
            uint8_t drain[64];
            while (read(wakeFD, drain, sizeof(drain)) > 0) {}
            return 0;
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

@implementation RLStreamSocket

- (instancetype)initWithFileDescriptor:(int)fd {
    self = [super init];
    if (!self) return nil;

    atomic_init(&_fd, fd);
    _wakePipe[0] = -1;
    _wakePipe[1] = -1;
    if (pipe(_wakePipe) == 0) {
        fcntl(_wakePipe[0], F_SETFL, O_NONBLOCK);
        fcntl(_wakePipe[1], F_SETFL, O_NONBLOCK);
    }

    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    }

    atomic_init(&_closedFlag, false);
    atomic_init(&_nudgedFlag, false);
    _readBuffer = [NSMutableData data];
    return self;
}

- (void)dealloc {
    [self close];
    int fd = atomic_exchange(&_fd, -1);
    if (fd >= 0) {
        close(fd);
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

- (BOOL)isClosed {
    return atomic_load(&_closedFlag);
}

- (BOOL)writeData:(NSData *)data
          timeout:(NSTimeInterval)timeout
            error:(NSError * _Nullable * _Nullable)error {
    if (self.isClosed) {
        if (error) *error = RLSockError(RLErrorSocketClosed, @"Socket is closed");
        return NO;
    }
    if (data.length == 0) return YES;

    _ioDeadline = RLMonotonicNow() + MAX(timeout, 0.1);
    const uint8_t *bytes = data.bytes;
    size_t offset = 0;
    size_t total = data.length;

    while (offset < total) {
        if (self.isClosed) {
            if (error) *error = RLSockError(RLErrorSocketClosed, @"Socket closed during write");
            return NO;
        }

        int fd = atomic_load(&_fd);
        if (fd < 0) {
            if (error) *error = RLSockError(RLErrorSocketClosed, @"Socket is closed");
            return NO;
        }
        ssize_t n = send(fd, bytes + offset, total - offset, 0);
        if (n > 0) {
            offset += (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            int ready = RLPollFD(fd, _wakePipe[0], &_closedFlag, POLLOUT, _ioDeadline);
            if (ready > 0) continue;
            if (ready == 0) {
                if (RLMonotonicNow() < _ioDeadline) {
                    continue;
                }
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
        if (_readBuffer.length == length) {
            [_readBuffer setLength:0];
        } else {
            [_readBuffer replaceBytesInRange:NSMakeRange(0, length) withBytes:NULL length:0];
        }
        return slice;
    }

    if (self.isClosed) {
        if (error) *error = RLSockError(RLErrorSocketClosed, @"Socket is closed");
        return nil;
    }

    _ioDeadline = RLMonotonicNow() + MAX(timeout, 0.001);
    uint8_t scratch[4096];

    while (_readBuffer.length < length) {
        if (self.isClosed) {
            if (error) *error = RLSockError(RLErrorSocketClosed, @"Socket closed during read");
            return nil;
        }

        size_t need = MIN(length - _readBuffer.length, sizeof(scratch));

        int fd = atomic_load(&_fd);
        if (fd < 0) {
            if (error) *error = RLSockError(RLErrorSocketClosed, @"Socket is closed");
            return nil;
        }
        ssize_t n = recv(fd, scratch, need, 0);
        if (n > 0) {
            [_readBuffer appendBytes:scratch length:(size_t)n];
            continue;
        }
        if (n == 0) {
            if (error) *error = RLSockError(RLErrorSocketClosed, @"Peer closed local stream");
            return nil;
        }
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            int ready = RLPollFD(fd, _wakePipe[0], &_closedFlag, POLLIN, _ioDeadline);
            if (ready > 0) continue;
            if (ready == 0) {
                if (RLMonotonicNow() >= _ioDeadline ||
                    (_readBuffer.length == 0 && atomic_exchange(&_nudgedFlag, false))) {
                    if (timedOut) *timedOut = YES;
                    return nil;
                }
                continue;
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

    NSData *slice = [_readBuffer subdataWithRange:NSMakeRange(0, length)];
    if (_readBuffer.length == length) {
        [_readBuffer setLength:0];
    } else {
        [_readBuffer replaceBytesInRange:NSMakeRange(0, length) withBytes:NULL length:0];
    }
    return slice;
}

- (void)nudge {
    if (atomic_load(&_closedFlag)) {
        return;
    }
    atomic_store(&_nudgedFlag, true);
    if (_wakePipe[1] >= 0) {
        uint8_t byte = 'W';
        (void)write(_wakePipe[1], &byte, 1);
    }
}

- (void)close {
    bool expected = false;
    if (atomic_compare_exchange_strong(&_closedFlag, &expected, true)) {
        if (_wakePipe[1] >= 0) {
            uint8_t byte = 1;
            (void)write(_wakePipe[1], &byte, 1);
        }
        int fd = atomic_load(&_fd);
        if (fd >= 0) {
            shutdown(fd, SHUT_RDWR);
        }
    }
}

@end

