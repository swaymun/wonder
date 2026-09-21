#ifndef WONDER_RELAY_H
#define WONDER_RELAY_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque pointers keep Rust ownership and zeroization behind the ABI. */
#define WONDER_RELAY_OK 0
#define WONDER_RELAY_INVALID_ARGUMENT 1
#define WONDER_RELAY_INVALID_KEY 2
#define WONDER_RELAY_INVALID_STATE 3
#define WONDER_RELAY_BUFFER_TOO_SMALL 4
#define WONDER_RELAY_AUTHENTICATION_FAILED 5
#define WONDER_RELAY_MESSAGE_TOO_LARGE 6
#define WONDER_RELAY_INVALID_FRAME 7
#define WONDER_RELAY_INTERNAL_ERROR 255

#define WONDER_RELAY_KEY_SIZE 32
#define WONDER_RELAY_MAX_FRAME_SIZE 65535
#define WONDER_RELAY_MAX_HANDSHAKE_MESSAGE_SIZE 1024

/*
 * Start/accept/finish mirror wonder-relay's Initiator, Responder and Session
 * types. The Rust side constructs the canonical, length-delimited prologue
 * from these three UTF-8 context fields; Swift never concatenates it itself.
 * `out_*` values are owned by Rust and must be released through the matching
 * function. Handshake payloads are always empty.
 */
int wonder_relay_initiator_start(
    const uint8_t *local_private_key, size_t local_private_key_len,
    const uint8_t *peer_public_key, size_t peer_public_key_len,
    const uint8_t *host_identity, size_t host_identity_len,
    const uint8_t *device_identity, size_t device_identity_len,
    const uint8_t *routing_identity, size_t routing_identity_len,
    void **out_initiator,
    uint8_t *message, size_t message_capacity, size_t *message_len
);

void wonder_relay_initiator_free(void *initiator);

int wonder_relay_initiator_finish(
    void *initiator,
    const uint8_t *message, size_t message_len,
    void **out_session
);
/* initiator_finish consumes `initiator` on every return path. */

int wonder_relay_responder_accept(
    const uint8_t *local_private_key, size_t local_private_key_len,
    const uint8_t *peer_public_key, size_t peer_public_key_len,
    const uint8_t *host_identity, size_t host_identity_len,
    const uint8_t *device_identity, size_t device_identity_len,
    const uint8_t *routing_identity, size_t routing_identity_len,
    const uint8_t *message, size_t message_len,
    uint8_t *response, size_t response_capacity, size_t *response_len,
    void **out_session
);

void wonder_relay_session_free(void *session);

int wonder_relay_seal_frame(
    void *session,
    const uint8_t *payload, size_t payload_len,
    uint8_t *frame, size_t frame_capacity, size_t *frame_len
);

int wonder_relay_open_frame(
    void *session,
    const uint8_t *frame, size_t frame_len,
    uint8_t *payload, size_t payload_capacity, size_t *payload_len
);

#ifdef __cplusplus
}
#endif

#endif
