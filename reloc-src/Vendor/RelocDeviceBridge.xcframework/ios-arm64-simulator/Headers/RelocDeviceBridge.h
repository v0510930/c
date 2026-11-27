#ifndef RELOC_DEVICE_BRIDGE_H
#define RELOC_DEVICE_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*RLDevicePairingEvent)(const char *event_json, void *context);

/// Starts iOS 27 on-device Remote Pairing responder. Emits ready/connected/pin/completed/failed/cancelled JSON events.
uint64_t rl_device_pairing_start(const char *request_json, RLDevicePairingEvent callback, void *context);

/// Cancels an active on-device pairing session.
void rl_device_pairing_cancel(uint64_t handle);

/// Checks if a Bonjour _remotepairing._tcp announcement matches the stored pairing record's alt_irk.
bool rl_device_pairing_matches(const uint8_t *record, size_t length, const char *identifier, const char *auth_tag);

/// Verifies Remote Pairing connectivity over host_ip:port, establishes tunnel + RSD handshake, and returns JSON.
/// Caller frees returned string with rl_string_free().
char *rl_device_pairing_verify(const uint8_t *record, size_t length, const char *host_ip, uint16_t port);

/// Opens an RSD/Lockdown service stream over a Remote Pairing tunnel and bridges it to a local POSIX socket fd.
/// Returns JSON: {"ok":true,"handle":123,"fd":45,"service":"..."} or {"ok":false,"error":"..."}.
/// Caller owns the returned fd and must call rl_rppairing_close_service(handle) when done.
char *rl_rppairing_open_service(const uint8_t *record,
                                size_t length,
                                const char *host_ip,
                                uint16_t port,
                                const char *preferred_service);

/// Stops the background tunnel & stream pump for an opened Remote Pairing service handle.
void rl_rppairing_close_service(uint64_t handle);

/// Frees a C string allocated by this bridge.
void rl_string_free(char *value);

#ifdef __cplusplus
}
#endif

#endif
