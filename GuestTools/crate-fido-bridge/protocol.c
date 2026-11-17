/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#include "protocol.h"

#include <string.h>

static const uint8_t magic[4] = {'C', 'F', 'D', '1'};

static uint16_t load_be16(const uint8_t *p) {
    return (uint16_t)((uint16_t)p[0] << 8 | p[1]);
}

static uint32_t load_be32(const uint8_t *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static void store_be16(uint8_t *p, uint16_t value) {
    p[0] = (uint8_t)(value >> 8);
    p[1] = (uint8_t)value;
}

static void store_be32(uint8_t *p, uint32_t value) {
    p[0] = (uint8_t)(value >> 24);
    p[1] = (uint8_t)(value >> 16);
    p[2] = (uint8_t)(value >> 8);
    p[3] = (uint8_t)value;
}

static uint32_t crc32_update(uint32_t crc, const uint8_t *bytes, size_t length) {
    for (size_t i = 0; i < length; i++) {
        crc ^= bytes[i];
        for (unsigned bit = 0; bit < 8; bit++) {
            uint32_t mask = (uint32_t)-(int32_t)(crc & 1u);
            crc = crc >> 1 ^ (0xedb88320u & mask);
        }
    }
    return crc;
}

uint32_t cfb_crc32(const void *bytes, size_t length) {
    return crc32_update(0xffffffffu, bytes, length) ^ 0xffffffffu;
}

static uint32_t frame_crc(const uint8_t *frame, uint16_t payload_length) {
    uint32_t crc = crc32_update(0xffffffffu, frame + 4, 8);
    crc = crc32_update(crc, frame + CFB_HEADER_SIZE, payload_length);
    return crc ^ 0xffffffffu;
}

size_t cfb_encode(uint8_t type, uint32_t sequence, const void *payload, uint16_t length,
                  uint8_t *output, size_t capacity) {
    size_t total = CFB_HEADER_SIZE + (size_t)length;
    if (output == NULL || length > CFB_MAX_PAYLOAD || capacity < total ||
        (length != 0 && payload == NULL)) {
        return 0;
    }
    memcpy(output, magic, sizeof magic);
    output[4] = CFB_PROTOCOL_VERSION;
    output[5] = type;
    store_be16(output + 6, length);
    store_be32(output + 8, sequence);
    memset(output + 12, 0, 4);
    if (length != 0) memcpy(output + CFB_HEADER_SIZE, payload, length);
    store_be32(output + 12, frame_crc(output, length));
    return total;
}

void cfb_parser_init(struct cfb_parser *parser) {
    if (parser != NULL) memset(parser, 0, sizeof *parser);
}

static void remove_prefix(struct cfb_parser *parser, size_t count) {
    if (count > parser->length) count = parser->length;
    if (count != 0 && count < parser->length) {
        memmove(parser->bytes, parser->bytes + count, parser->length - count);
    }
    parser->length -= count;
}

static void discard(struct cfb_parser *parser, size_t count) {
    if (count > parser->length) count = parser->length;
    parser->discarded_bytes += count;
    remove_prefix(parser, count);
}

static size_t magic_prefix_at_end(const uint8_t *bytes, size_t length) {
    size_t maximum = length < sizeof magic - 1 ? length : sizeof magic - 1;
    for (size_t keep = maximum; keep != 0; keep--) {
        if (memcmp(bytes + length - keep, magic, keep) == 0) return keep;
    }
    return 0;
}

static int parse_available(struct cfb_parser *parser, cfb_message_callback callback,
                           void *context) {
    for (;;) {
        size_t marker = 0;
        while (marker + sizeof magic <= parser->length &&
               memcmp(parser->bytes + marker, magic, sizeof magic) != 0) {
            marker++;
        }
        if (marker + sizeof magic > parser->length) {
            size_t keep = magic_prefix_at_end(parser->bytes, parser->length);
            discard(parser, parser->length - keep);
            return 0;
        }
        if (marker != 0) discard(parser, marker);
        if (parser->length < CFB_HEADER_SIZE) return 0;

        uint8_t version = parser->bytes[4];
        uint16_t payload_length = load_be16(parser->bytes + 6);
        if (version != CFB_PROTOCOL_VERSION || payload_length > CFB_MAX_PAYLOAD) {
            parser->bad_headers++;
            discard(parser, 1);
            continue;
        }
        size_t total = CFB_HEADER_SIZE + (size_t)payload_length;
        if (parser->length < total) return 0;
        uint32_t expected = load_be32(parser->bytes + 12);
        if (frame_crc(parser->bytes, payload_length) != expected) {
            parser->bad_checksums++;
            discard(parser, 1);
            continue;
        }

        struct cfb_message message;
        memset(&message, 0, sizeof message);
        message.version = version;
        message.type = parser->bytes[5];
        message.length = payload_length;
        message.sequence = load_be32(parser->bytes + 8);
        if (payload_length != 0) {
            memcpy(message.payload, parser->bytes + CFB_HEADER_SIZE, payload_length);
        }
        remove_prefix(parser, total);
        int result = callback == NULL ? 0 : callback(context, &message);
        if (result != 0) return result;
    }
}

int cfb_parser_feed(struct cfb_parser *parser, const void *bytes, size_t length,
                    cfb_message_callback callback, void *context) {
    if (parser == NULL || (length != 0 && bytes == NULL)) return -1;
    const uint8_t *input = bytes;
    while (length != 0) {
        int result = parse_available(parser, callback, context);
        if (result != 0) return result;
        size_t room = sizeof parser->bytes - parser->length;
        if (room == 0) {
            /* A valid frame is at most 80 bytes. A full parser with no complete
             * frame is necessarily corrupt or hostile; advance one byte. */
            discard(parser, 1);
            continue;
        }
        size_t take = length < room ? length : room;
        memcpy(parser->bytes + parser->length, input, take);
        parser->length += take;
        input += take;
        length -= take;
    }
    return parse_available(parser, callback, context);
}
