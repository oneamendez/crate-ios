CC ?= cc
CFLAGS ?= -O2 -g
WARNINGS = -Wall -Wextra -Wpedantic -Werror -Wconversion -Wshadow
COMMON = -std=c11 $(WARNINGS)
UNAME_S := $(shell uname -s)

.PHONY: all clean test check

ifeq ($(UNAME_S),Linux)
all: crate-fido-bridge
else
all: test_protocol
	@echo "crate-fido-bridge: Linux is required for the UHID executable; protocol tests are portable."
endif

crate-fido-bridge: crate-fido-bridge.c protocol.c protocol.h
	$(CC) $(CPPFLAGS) $(CFLAGS) $(COMMON) crate-fido-bridge.c protocol.c $(LDFLAGS) $(LDLIBS) -o $@

test_protocol: test_protocol.c protocol.c protocol.h
	$(CC) $(CPPFLAGS) $(CFLAGS) $(COMMON) test_protocol.c protocol.c $(LDFLAGS) $(LDLIBS) -o $@

test: test_protocol
	./test_protocol

check: all test

clean:
	$(RM) crate-fido-bridge test_protocol
