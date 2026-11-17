/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#ifndef CRATE_FIDO_PROTOCOL_H
#define CRATE_FIDO_PROTOCOL_H

#include <stddef.h>
#include <stdint.h>

#define CFB_PROTOCOL_VERSION 1u
#define CFB_HEADER_SIZE 16u
#define CFB_MAX_PAYLOAD 64u
#define CFB_MAX_FRAME_SIZE (CFB_HEADER_SIZE + CFB_MAX_PAYLOAD)
#define CFB_PARSER_CAPACITY 4096u
#define CFB_NONCE_SIZE 16u
#define CFB_REPORT_SIZE 64u

enum cfb_message_type {
    CFB_MSG_HELLO = 0x01,
    CFB_MSG_HELLO_ACK = 0x02,
    CFB_MSG_GUEST_REPORT = 0x10,
    CFB_MSG_HOST_REPORT = 0x11,
};

struct cfb_message {
    uint8_t version;
    uint8_t type;
    uint16_t length;
    uint32_t sequence;
    uint8_t payload[CFB_MAX_PAYLOAD];
};

typedef int (*cfb_message_callback)(void *context, const struct cfb_message *message);

struct cfb_parser {
    uint8_t bytes[CFB_PARSER_CAPACITY];
    size_t length;
    uint64_t discarded_bytes;
    uint64_t bad_headers;
    uint64_t bad_checksums;
};

uint32_t cfb_crc32(const void *bytes, size_t length);

/* Encodes one frame into `output`. Returns its exact length, or zero when the
 * message is invalid or `capacity` is too small. */
size_t cfb_encode(uint8_t type, uint32_t sequence, const void *payload, uint16_t length,
                  uint8_t *output, size_t capacity);

void cfb_parser_init(struct cfb_parser *parser);

/* Adds arbitrary stream bytes. Complete, checksum-valid frames are handed to
 * `callback`. Garbage, corrupt frames and unsupported versions are discarded
 * with byte-wise resynchronization on the next magic marker. Returns zero, or
 * the first nonzero value returned by `callback`. */
int cfb_parser_feed(struct cfb_parser *parser, const void *bytes, size_t length,
                    cfb_message_callback callback, void *context);

#endif
