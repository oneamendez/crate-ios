/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#define _GNU_SOURCE

#include "protocol.h"

#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <linux/input.h>
#include <linux/uhid.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/random.h>
#include <sys/stat.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#define OUTGOING_CAPACITY 64u
#define HELLO_INTERVAL_MS 2000
#define UHID_WRITE_TIMEOUT_MS 5000

/* FIDO Alliance Usage Page 0xf1d0, CTAPHID Usage 0x01, with one exact
 * 64-byte input report and one exact 64-byte output report. No report ID is
 * used, as required by the ordinary CTAPHID USB transport. */
static const uint8_t fido_report_descriptor[] = {
    0x06, 0xd0, 0xf1,       /* Usage Page (FIDO Alliance) */
    0x09, 0x01,             /* Usage (CTAPHID) */
    0xa1, 0x01,             /* Collection (Application) */
    0x09, 0x20,             /*   Usage (Input Report Data) */
    0x15, 0x00,             /*   Logical Minimum (0) */
    0x26, 0xff, 0x00,       /*   Logical Maximum (255) */
    0x75, 0x08,             /*   Report Size (8) */
    0x95, 0x40,             /*   Report Count (64) */
    0x81, 0x02,             /*   Input (Data, Variable, Absolute) */
    0x09, 0x21,             /*   Usage (Output Report Data) */
    0x15, 0x00,             /*   Logical Minimum (0) */
    0x26, 0xff, 0x00,       /*   Logical Maximum (255) */
    0x75, 0x08,             /*   Report Size (8) */
    0x95, 0x40,             /*   Report Count (64) */
    0x91, 0x02,             /*   Output (Data, Variable, Absolute) */
    0xc0,                   /* End Collection */
};

struct queued_frame {
    uint8_t bytes[CFB_MAX_FRAME_SIZE];
    size_t length;
    size_t offset;
};

struct outgoing_queue {
    struct queued_frame frames[OUTGOING_CAPACITY];
    size_t head;
    size_t count;
};

struct bridge {
    int console_fd;
    int uhid_fd;
    const char *console_path;
    const char *uhid_path;
    struct termios saved_termios;
    bool saved_termios_valid;
    bool uhid_created;
    bool handshaken;
    bool reset_requested;
    bool verbose;
    uint8_t nonce[CFB_NONCE_SIZE];
    uint32_t guest_sequence;
    uint32_t expected_host_sequence;
    int64_t next_hello_ms;
    struct outgoing_queue outgoing;
    struct cfb_parser parser;
};

static volatile sig_atomic_t stopping;

static void on_signal(int signal_number) {
    (void)signal_number;
    stopping = 1;
}

static int64_t monotonic_ms(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int random_bytes(void *output, size_t length) {
    uint8_t *bytes = output;
    size_t done = 0;
    while (done < length) {
        ssize_t n = getrandom(bytes + done, length - done, 0);
        if (n > 0) {
            done += (size_t)n;
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else {
            return -1;
        }
    }
    return 0;
}

static void queue_clear(struct outgoing_queue *queue) {
    memset(queue, 0, sizeof *queue);
}

static int queue_message(struct bridge *bridge, uint8_t type, const void *payload,
                         uint16_t length) {
    struct outgoing_queue *queue = &bridge->outgoing;
    if (queue->count == OUTGOING_CAPACITY) {
        errno = ENOBUFS;
        return -1;
    }
    size_t index = (queue->head + queue->count) % OUTGOING_CAPACITY;
    struct queued_frame *frame = &queue->frames[index];
    frame->length = cfb_encode(type, bridge->guest_sequence++, payload, length,
                               frame->bytes, sizeof frame->bytes);
    frame->offset = 0;
    if (frame->length == 0) {
        errno = EINVAL;
        return -1;
    }
    queue->count++;
    return 0;
}

static int flush_console(struct bridge *bridge) {
    struct outgoing_queue *queue = &bridge->outgoing;
    while (queue->count != 0) {
        struct queued_frame *frame = &queue->frames[queue->head];
        ssize_t n = write(bridge->console_fd, frame->bytes + frame->offset,
                          frame->length - frame->offset);
        if (n > 0) {
            frame->offset += (size_t)n;
            if (frame->offset == frame->length) {
                memset(frame, 0, sizeof *frame);
                queue->head = (queue->head + 1) % OUTGOING_CAPACITY;
                queue->count--;
            }
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
        if (n == 0) errno = EIO;
        return -1;
    }
    return 0;
}

/* UHID is a record-oriented character device. A short event from the kernel is
 * a complete event with its tail implicitly zero; a short positive write would
 * likewise complete a truncated record, so it must be treated as an error and
 * never followed by a second write. EINTR and EAGAIN before any byte are safe
 * to retry. */
static int write_uhid_record(struct bridge *bridge, const struct uhid_event *event,
                             size_t length) {
    int64_t deadline = monotonic_ms() + UHID_WRITE_TIMEOUT_MS;
    for (;;) {
        ssize_t n = write(bridge->uhid_fd, event, length);
        if (n == (ssize_t)length) return 0;
        if (n > 0) {
            errno = EPROTO;
            return -1;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            int64_t remaining = deadline - monotonic_ms();
            if (remaining <= 0) {
                errno = ETIMEDOUT;
                return -1;
            }
            int timeout = remaining > 1000 ? 1000 : (int)remaining;
            struct pollfd fd = {.fd = bridge->uhid_fd, .events = POLLOUT};
            int result;
            do result = poll(&fd, 1, timeout); while (result < 0 && errno == EINTR && !stopping);
            if (result < 0) return -1;
            continue;
        }
        if (n == 0) errno = EIO;
        return -1;
    }
}

static int create_uhid(struct bridge *bridge) {
    if (bridge->uhid_created) return 0;
    struct uhid_event event;
    memset(&event, 0, sizeof event);
    event.type = UHID_CREATE2;
    snprintf((char *)event.u.create2.name, sizeof event.u.create2.name,
             "Crate Virtual FIDO2 Authenticator");
    snprintf((char *)event.u.create2.phys, sizeof event.u.create2.phys,
             "crate-fido/hvc0");
    snprintf((char *)event.u.create2.uniq, sizeof event.u.create2.uniq,
             "crate-fido-v1");
    event.u.create2.rd_size = (uint16_t)sizeof fido_report_descriptor;
    event.u.create2.bus = BUS_USB;
    /* Discovery is by the FIDO usage page, not a borrowed vendor/product ID. */
    event.u.create2.vendor = 0;
    event.u.create2.product = 0;
    event.u.create2.version = 1;
    memcpy(event.u.create2.rd_data, fido_report_descriptor, sizeof fido_report_descriptor);
    size_t length = offsetof(struct uhid_event, u.create2.rd_data) + sizeof fido_report_descriptor;
    if (write_uhid_record(bridge, &event, length) != 0) return -1;
    bridge->uhid_created = true;
    fprintf(stderr, "crate-fido: virtual authenticator connected\n");
    return 0;
}

static void destroy_uhid(struct bridge *bridge) {
    if (!bridge->uhid_created) return;
    struct uhid_event event;
    memset(&event, 0, sizeof event);
    event.type = UHID_DESTROY;
    if (write_uhid_record(bridge, &event, sizeof event.type) != 0 && bridge->verbose) {
        fprintf(stderr, "crate-fido: UHID destroy failed: %s\n", strerror(errno));
    }
    bridge->uhid_created = false;
}

static int send_uhid_report(struct bridge *bridge, const uint8_t report[CFB_REPORT_SIZE]) {
    struct uhid_event event;
    memset(&event, 0, sizeof event);
    event.type = UHID_INPUT2;
    event.u.input2.size = CFB_REPORT_SIZE;
    memcpy(event.u.input2.data, report, CFB_REPORT_SIZE);
    size_t length = offsetof(struct uhid_event, u.input2.data) + CFB_REPORT_SIZE;
    return write_uhid_record(bridge, &event, length);
}

static int reply_get_report(struct bridge *bridge, uint32_t id) {
    struct uhid_event event;
    memset(&event, 0, sizeof event);
    event.type = UHID_GET_REPORT_REPLY;
    event.u.get_report_reply.id = id;
    event.u.get_report_reply.err = (uint16_t)EOPNOTSUPP;
    size_t length = offsetof(struct uhid_event, u.get_report_reply.data);
    return write_uhid_record(bridge, &event, length);
}

static int reply_set_report(struct bridge *bridge, uint32_t id) {
    struct uhid_event event;
    memset(&event, 0, sizeof event);
    event.type = UHID_SET_REPORT_REPLY;
    event.u.set_report_reply.id = id;
    event.u.set_report_reply.err = (uint16_t)EOPNOTSUPP;
    size_t length = offsetof(struct uhid_event, u.set_report_reply) +
                    sizeof event.u.set_report_reply;
    return write_uhid_record(bridge, &event, length);
}

static int receive_uhid_event(struct bridge *bridge) {
    struct uhid_event event;
    memset(&event, 0, sizeof event);
    ssize_t n;
    do n = read(bridge->uhid_fd, &event, sizeof event); while (n < 0 && errno == EINTR);
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
    if (n <= 0) {
        if (n == 0) errno = EIO;
        return -1;
    }
    if ((size_t)n < sizeof event.type) {
        errno = EPROTO;
        return -1;
    }
    switch (event.type) {
    case UHID_START:
        if (bridge->verbose) fprintf(stderr, "crate-fido: UHID started\n");
        break;
    case UHID_STOP:
        if (bridge->verbose) fprintf(stderr, "crate-fido: UHID stopped\n");
        break;
    case UHID_OPEN:
        if (bridge->verbose) fprintf(stderr, "crate-fido: browser opened the authenticator\n");
        break;
    case UHID_CLOSE:
        if (bridge->verbose) fprintf(stderr, "crate-fido: browser closed the authenticator\n");
        break;
    case UHID_OUTPUT:
        if (event.u.output.rtype != UHID_OUTPUT_REPORT ||
            event.u.output.size != CFB_REPORT_SIZE) {
            fprintf(stderr, "crate-fido: rejected UHID output type %u size %u\n",
                    event.u.output.rtype, event.u.output.size);
            break;
        }
        if (queue_message(bridge, CFB_MSG_GUEST_REPORT, event.u.output.data,
                          CFB_REPORT_SIZE) != 0) {
            return -1;
        }
        break;
    case UHID_GET_REPORT:
        return reply_get_report(bridge, event.u.get_report.id);
    case UHID_SET_REPORT:
        return reply_set_report(bridge, event.u.set_report.id);
    default:
        if (bridge->verbose) fprintf(stderr, "crate-fido: ignored UHID event %u\n", event.type);
        break;
    }
    return 0;
}

static int received_message(void *opaque, const struct cfb_message *message) {
    struct bridge *bridge = opaque;
    if (message->type == CFB_MSG_HELLO_ACK) {
        /* A delayed duplicate ACK must not rewind the live host sequence. */
        if (bridge->handshaken) {
            if (bridge->verbose) fprintf(stderr, "crate-fido: ignored a duplicate hello acknowledgement\n");
            return 0;
        }
        if (message->length != CFB_NONCE_SIZE ||
            memcmp(message->payload, bridge->nonce, CFB_NONCE_SIZE) != 0) {
            if (bridge->verbose) fprintf(stderr, "crate-fido: ignored a stale hello acknowledgement\n");
            return 0;
        }
        bridge->expected_host_sequence = message->sequence + 1;
        if (create_uhid(bridge) != 0) return -1;
        bridge->handshaken = true;
        fprintf(stderr, "crate-fido: host transport ready\n");
        return 0;
    }
    if (message->type != CFB_MSG_HOST_REPORT) {
        if (bridge->verbose) fprintf(stderr, "crate-fido: ignored host message type %#x\n", message->type);
        return 0;
    }
    if (!bridge->handshaken) return 0;
    if (message->sequence != bridge->expected_host_sequence) {
        fprintf(stderr, "crate-fido: host sequence changed; renegotiating\n");
        bridge->handshaken = false;
        bridge->reset_requested = true;
        return 0;
    }
    bridge->expected_host_sequence++;
    if (message->length != CFB_REPORT_SIZE) {
        fprintf(stderr, "crate-fido: rejected host report size %u\n", message->length);
        bridge->handshaken = false;
        bridge->reset_requested = true;
        return 0;
    }
    return send_uhid_report(bridge, message->payload);
}

static int read_console(struct bridge *bridge) {
    uint8_t bytes[1024];
    for (;;) {
        ssize_t n = read(bridge->console_fd, bytes, sizeof bytes);
        if (n > 0) {
            int result = cfb_parser_feed(&bridge->parser, bytes, (size_t)n,
                                         received_message, bridge);
            if (result != 0) return result;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
        if (n == 0) errno = EIO;
        return -1;
    }
}

static int open_console(struct bridge *bridge) {
    int fd = open(bridge->console_path, O_RDWR | O_NOCTTY | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return -1;
    if (ioctl(fd, TIOCEXCL) != 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    struct termios raw;
    if (tcgetattr(fd, &bridge->saved_termios) != 0) {
        int saved = errno;
        ioctl(fd, TIOCNXCL);
        close(fd);
        errno = saved;
        return -1;
    }
    bridge->saved_termios_valid = true;
    raw = bridge->saved_termios;
    cfmakeraw(&raw);
    raw.c_cflag |= CLOCAL | CREAD;
    raw.c_cc[VMIN] = 1;
    raw.c_cc[VTIME] = 0;
    if (tcsetattr(fd, TCSANOW, &raw) != 0 || tcflush(fd, TCIOFLUSH) != 0) {
        int saved = errno;
        tcsetattr(fd, TCSANOW, &bridge->saved_termios);
        ioctl(fd, TIOCNXCL);
        close(fd);
        errno = saved;
        return -1;
    }
    bridge->console_fd = fd;
    return 0;
}

static void close_console(struct bridge *bridge) {
    if (bridge->console_fd < 0) return;
    if (bridge->saved_termios_valid) {
        tcsetattr(bridge->console_fd, TCSANOW, &bridge->saved_termios);
    }
    ioctl(bridge->console_fd, TIOCNXCL);
    close(bridge->console_fd);
    bridge->console_fd = -1;
    bridge->saved_termios_valid = false;
}

static int begin_handshake(struct bridge *bridge) {
    destroy_uhid(bridge);
    bridge->handshaken = false;
    bridge->reset_requested = false;
    bridge->guest_sequence = 0;
    bridge->expected_host_sequence = 0;
    bridge->next_hello_ms = 0;
    queue_clear(&bridge->outgoing);
    cfb_parser_init(&bridge->parser);
    if (random_bytes(bridge->nonce, sizeof bridge->nonce) != 0) return -1;
    return 0;
}

static int run(struct bridge *bridge) {
    if (open_console(bridge) != 0) return -1;
    bridge->uhid_fd = open(bridge->uhid_path, O_RDWR | O_CLOEXEC | O_NONBLOCK);
    if (bridge->uhid_fd < 0) return -1;
    if (begin_handshake(bridge) != 0) return -1;

    while (!stopping) {
        if (bridge->reset_requested && begin_handshake(bridge) != 0) return -1;
        int64_t now = monotonic_ms();
        if (!bridge->handshaken && now >= bridge->next_hello_ms &&
            bridge->outgoing.count == 0) {
            if (queue_message(bridge, CFB_MSG_HELLO, bridge->nonce, CFB_NONCE_SIZE) != 0) return -1;
            bridge->next_hello_ms = now + HELLO_INTERVAL_MS;
        }

        struct pollfd fds[2];
        memset(fds, 0, sizeof fds);
        fds[0].fd = bridge->console_fd;
        fds[0].events = POLLIN;
        if (bridge->outgoing.count != 0) fds[0].events |= POLLOUT;
        fds[1].fd = bridge->uhid_fd;
        if (bridge->uhid_created && bridge->outgoing.count < OUTGOING_CAPACITY) {
            fds[1].events = POLLIN;
        }
        int timeout = 1000;
        if (!bridge->handshaken) {
            int64_t until_hello = bridge->next_hello_ms - now;
            if (until_hello < 0) until_hello = 0;
            if (until_hello < timeout) timeout = (int)until_hello;
        }
        int result = poll(fds, 2, timeout);
        if (result < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if ((fds[0].revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
            errno = EIO;
            return -1;
        }
        if ((fds[1].revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
            errno = EIO;
            return -1;
        }
        if ((fds[0].revents & POLLIN) != 0 && read_console(bridge) != 0) return -1;
        /* Do not flush old-session reports or consume another UHID record once
         * a parser callback has invalidated the transport session. */
        if (bridge->reset_requested) {
            if (begin_handshake(bridge) != 0) return -1;
            continue;
        }
        if ((fds[0].revents & POLLOUT) != 0 && flush_console(bridge) != 0) return -1;
        if ((fds[1].revents & POLLIN) != 0 && receive_uhid_event(bridge) != 0) return -1;
    }
    return 0;
}

static void usage(FILE *stream, const char *program) {
    fprintf(stream,
            "Usage: %s [--console PATH] [--uhid PATH] [--verbose]\n"
            "\n"
            "Create a Linux UHID FIDO device and forward exact CTAPHID reports over\n"
            "Crate's dedicated virtio console. Defaults: /dev/hvc0, /dev/uhid.\n",
            program);
}

int main(int argc, char **argv) {
    struct bridge bridge;
    memset(&bridge, 0, sizeof bridge);
    bridge.console_fd = -1;
    bridge.uhid_fd = -1;
    bridge.console_path = "/dev/hvc0";
    bridge.uhid_path = "/dev/uhid";
    static const struct option options[] = {
        {"console", required_argument, NULL, 'c'},
        {"uhid", required_argument, NULL, 'u'},
        {"verbose", no_argument, NULL, 'v'},
        {"help", no_argument, NULL, 'h'},
        {NULL, 0, NULL, 0},
    };
    for (;;) {
        int option = getopt_long(argc, argv, "c:u:vh", options, NULL);
        if (option == -1) break;
        switch (option) {
        case 'c': bridge.console_path = optarg; break;
        case 'u': bridge.uhid_path = optarg; break;
        case 'v': bridge.verbose = true; break;
        case 'h': usage(stdout, argv[0]); return EXIT_SUCCESS;
        default: usage(stderr, argv[0]); return EXIT_FAILURE;
        }
    }
    if (optind != argc) {
        usage(stderr, argv[0]);
        return EXIT_FAILURE;
    }
    umask(0077);
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_handler = on_signal;
    sigemptyset(&action.sa_mask);
    sigaction(SIGINT, &action, NULL);
    sigaction(SIGTERM, &action, NULL);
    signal(SIGPIPE, SIG_IGN);

    int result = run(&bridge);
    int saved = errno;
    destroy_uhid(&bridge);
    if (bridge.uhid_fd >= 0) close(bridge.uhid_fd);
    close_console(&bridge);
    if (result != 0 && !stopping) {
        fprintf(stderr, "crate-fido: stopped: %s\n", strerror(saved));
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}
