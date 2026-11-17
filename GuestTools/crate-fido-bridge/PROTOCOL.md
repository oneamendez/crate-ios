# Crate FIDO console transport v1

This is a transport for standard 64-byte CTAPHID reports. It does not parse
CTAP, hold credentials, or make authentication decisions. The iPhone side is
the authenticator; this Linux helper is only a byte-exact HID-to-console relay.

The console is an arbitrary byte stream. Every integer below is unsigned and
big-endian.

## Frame

| Offset | Size | Meaning |
| --- | ---: | --- |
| 0 | 4 | ASCII magic `CFD1` |
| 4 | 1 | protocol version, exactly `1` |
| 5 | 1 | message type |
| 6 | 2 | payload length, at most 64 |
| 8 | 4 | per-sender sequence number |
| 12 | 4 | IEEE CRC-32 |
| 16 | length | payload |

The checksum is CRC-32/ISO-HDLC (polynomial `0xedb88320`, initial and final XOR
`0xffffffff`) over header bytes 4 through 11 followed by the payload. It does
not include the magic or checksum field. CRC is for stream resynchronization,
not authentication.

The parser scans for `CFD1`, rejects unsupported versions and lengths before
waiting for a payload, verifies the checksum, and advances one byte after a bad
candidate. A sender must never put more than 64 bytes in one frame.

## Handshake and messages

Each direction has its own wrapping 32-bit sequence. A fresh guest process
chooses a random 16-byte nonce and sends:

| Type | Direction | Payload |
| --- | --- | --- |
| `0x01` HELLO | guest to host | 16-byte random nonce |
| `0x02` HELLO_ACK | host to guest | the exact same nonce |
| `0x10` GUEST_REPORT | guest to host | exactly one 64-byte CTAPHID output report |
| `0x11` HOST_REPORT | host to guest | exactly one 64-byte CTAPHID input report |

The guest repeats HELLO every two seconds until it receives a matching ACK. It
does not create the UHID device before that ACK, so Linux never sees an
authenticator with no live iPhone backend. The ACK establishes the expected
host sequence for the next frame. A stale nonce is ignored. A changed host
sequence or malformed report tears down UHID and starts a fresh handshake.

The host should treat a HELLO with a **new nonce** as session replacement for
that VM console: discard incomplete CTAPHID transactions, echo the nonce, then
begin a new host sequence. A repeated HELLO with the same nonce is a retry: the
host updates the next expected guest sequence from that HELLO, but repeats the
same HELLO_ACK frame and does not advance or rewind its own sequence. This lets
an ACK be lost or delayed without splitting the two endpoints' sequence state.
The host must never carry a transaction or response across a VM stop, console
detach, or new-nonce HELLO replacement.

The console is private to the current VM, but the nonce is only a lifecycle
binding—not a credential or defense against a malicious process in that guest.
Neither side should log report payloads.
