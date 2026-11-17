/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#include "protocol.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;

#define CHECK(condition, message)                                                     \
    do {                                                                              \
        if (!(condition)) {                                                           \
            fprintf(stderr, "FAIL: %s (%s:%d)\n", message, __FILE__, __LINE__);      \
            failures++;                                                               \
        }                                                                             \
    } while (0)

struct received {
    struct cfb_message messages[16];
    size_t count;
};

static int collect(void *opaque, const struct cfb_message *message) {
    struct received *received = opaque;
    if (received->count >= sizeof received->messages / sizeof received->messages[0]) return -9;
    received->messages[received->count++] = *message;
    return 0;
}

static size_t report_frame(uint8_t *frame, uint8_t type, uint32_t sequence, uint8_t seed) {
    uint8_t report[CFB_REPORT_SIZE];
    for (size_t i = 0; i < sizeof report; i++) report[i] = (uint8_t)(seed + i);
    return cfb_encode(type, sequence, report, sizeof report, frame, CFB_MAX_FRAME_SIZE);
}

static void split_at_every_byte(void) {
    uint8_t frame[CFB_MAX_FRAME_SIZE];
    size_t length = report_frame(frame, CFB_MSG_HOST_REPORT, 7, 3);
    CHECK(length == CFB_MAX_FRAME_SIZE, "a report has the fixed 80-byte framed size");
    for (size_t split = 0; split <= length; split++) {
        struct cfb_parser parser;
        struct received received = {0};
        cfb_parser_init(&parser);
        CHECK(cfb_parser_feed(&parser, frame, split, collect, &received) == 0,
              "the first partial feed succeeds");
        CHECK(cfb_parser_feed(&parser, frame + split, length - split, collect, &received) == 0,
              "the second partial feed succeeds");
        CHECK(received.count == 1, "every split yields exactly one message");
        if (received.count == 1) {
            CHECK(received.messages[0].sequence == 7, "the sequence survives framing");
            CHECK(received.messages[0].length == CFB_REPORT_SIZE, "the report remains 64 bytes");
            for (size_t i = 0; i < CFB_REPORT_SIZE; i++) {
                CHECK(received.messages[0].payload[i] == (uint8_t)(3 + i),
                      "the report payload is byte-exact");
            }
        }
    }
}

static void coalesced_and_garbage(void) {
    uint8_t a[CFB_MAX_FRAME_SIZE], b[CFB_MAX_FRAME_SIZE];
    size_t an = report_frame(a, CFB_MSG_GUEST_REPORT, 10, 1);
    size_t bn = report_frame(b, CFB_MSG_HOST_REPORT, 11, 2);
    uint8_t stream[2 * CFB_MAX_FRAME_SIZE + 32];
    size_t n = 0;
    const uint8_t garbage[] = {0x00, 'C', 'F', 0xff, 'C', 'F', 'D'};
    memcpy(stream + n, garbage, sizeof garbage); n += sizeof garbage;
    memcpy(stream + n, a, an); n += an;
    memcpy(stream + n, b, bn); n += bn;

    struct cfb_parser parser;
    struct received received = {0};
    cfb_parser_init(&parser);
    CHECK(cfb_parser_feed(&parser, stream, n, collect, &received) == 0,
          "garbage followed by coalesced frames parses");
    CHECK(received.count == 2, "both coalesced frames are delivered");
    CHECK(received.messages[0].type == CFB_MSG_GUEST_REPORT &&
          received.messages[1].type == CFB_MSG_HOST_REPORT,
          "coalesced frames stay ordered");
    CHECK(parser.discarded_bytes == sizeof garbage, "only garbage is counted as discarded");
}

static void corrupt_and_oversized(void) {
    uint8_t corrupt[CFB_MAX_FRAME_SIZE], good[CFB_MAX_FRAME_SIZE];
    size_t cn = report_frame(corrupt, CFB_MSG_HOST_REPORT, 20, 4);
    size_t gn = report_frame(good, CFB_MSG_HOST_REPORT, 21, 5);
    corrupt[CFB_HEADER_SIZE + 9] ^= 0x80;
    uint8_t stream[2 * CFB_MAX_FRAME_SIZE];
    memcpy(stream, corrupt, cn);
    memcpy(stream + cn, good, gn);

    struct cfb_parser parser;
    struct received received = {0};
    cfb_parser_init(&parser);
    CHECK(cfb_parser_feed(&parser, stream, cn + gn, collect, &received) == 0,
          "a corrupt frame does not poison the following frame");
    CHECK(received.count == 1 && received.messages[0].sequence == 21,
          "only the checksum-valid frame is delivered");
    CHECK(parser.bad_checksums == 1, "the checksum failure is counted");

    uint8_t invalid[CFB_HEADER_SIZE] = {'C', 'F', 'D', '1', CFB_PROTOCOL_VERSION,
                                        CFB_MSG_HOST_REPORT, 0, CFB_MAX_PAYLOAD + 1};
    uint8_t invalid_then_good[CFB_HEADER_SIZE + CFB_MAX_FRAME_SIZE];
    memcpy(invalid_then_good, invalid, sizeof invalid);
    memcpy(invalid_then_good + sizeof invalid, good, gn);
    received.count = 0;
    cfb_parser_init(&parser);
    CHECK(cfb_parser_feed(&parser, invalid_then_good, sizeof invalid_then_good,
                          collect, &received) == 0,
          "an oversized header is rejected without consuming the following frame");
    CHECK(received.count == 1 && received.messages[0].sequence == 21 &&
          parser.bad_headers == 1,
          "the parser recovers immediately after an oversized header");
}

static void long_garbage_is_bounded(void) {
    uint8_t garbage[CFB_PARSER_CAPACITY * 3];
    memset(garbage, 0xa5, sizeof garbage);
    uint8_t frame[CFB_MAX_FRAME_SIZE];
    size_t length = report_frame(frame, CFB_MSG_HOST_REPORT, 99, 7);
    struct cfb_parser parser;
    struct received received = {0};
    cfb_parser_init(&parser);
    CHECK(cfb_parser_feed(&parser, garbage, sizeof garbage, collect, &received) == 0,
          "arbitrarily long garbage is consumed within the fixed parser buffer");
    CHECK(parser.length <= 3 && received.count == 0,
          "long garbage retains at most a possible magic prefix");
    CHECK(cfb_parser_feed(&parser, frame, length, collect, &received) == 0,
          "a valid frame after long garbage parses");
    CHECK(received.count == 1 && received.messages[0].sequence == 99,
          "long garbage cannot poison the next valid frame");
}

static void hello_and_callback_error(void) {
    uint8_t nonce[CFB_NONCE_SIZE], frame[CFB_MAX_FRAME_SIZE];
    for (size_t i = 0; i < sizeof nonce; i++) nonce[i] = (uint8_t)i;
    size_t length = cfb_encode(CFB_MSG_HELLO_ACK, 1, nonce, sizeof nonce,
                               frame, sizeof frame);
    struct cfb_parser parser;
    struct received received = {0};
    cfb_parser_init(&parser);
    CHECK(cfb_parser_feed(&parser, frame, length, collect, &received) == 0,
          "a hello acknowledgement parses");
    CHECK(received.count == 1 && received.messages[0].length == CFB_NONCE_SIZE &&
          memcmp(received.messages[0].payload, nonce, sizeof nonce) == 0,
          "the acknowledgement nonce is exact");

    received.count = sizeof received.messages / sizeof received.messages[0];
    cfb_parser_init(&parser);
    CHECK(cfb_parser_feed(&parser, frame, length, collect, &received) == -9,
          "a callback error stops parsing and is returned");
}

static void encoder_bounds(void) {
    uint8_t payload[CFB_MAX_PAYLOAD + 1] = {0};
    uint8_t frame[CFB_MAX_FRAME_SIZE];
    CHECK(cfb_encode(CFB_MSG_HOST_REPORT, 0, payload, CFB_MAX_PAYLOAD + 1,
                     frame, sizeof frame) == 0,
          "the encoder rejects oversized payloads");
    CHECK(cfb_encode(CFB_MSG_HOST_REPORT, 0, payload, CFB_MAX_PAYLOAD,
                     frame, sizeof frame - 1) == 0,
          "the encoder rejects a short destination");
    CHECK(cfb_crc32("123456789", 9) == 0xcbf43926u,
          "CRC-32 matches the standard check vector");
}

int main(void) {
    split_at_every_byte();
    coalesced_and_garbage();
    corrupt_and_oversized();
    long_garbage_is_bounded();
    hello_and_callback_error();
    encoder_bounds();
    if (failures != 0) {
        fprintf(stderr, "crate-fido protocol: %d failure(s)\n", failures);
        return EXIT_FAILURE;
    }
    puts("crate-fido protocol: all checks passed");
    return EXIT_SUCCESS;
}
