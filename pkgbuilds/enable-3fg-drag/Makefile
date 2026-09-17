CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra -fPIC
LDFLAGS ?= -shared
# Header path only — no -linput. Every libinput symbol is resolved at
# runtime via RTLD_NEXT, so the shim has no hard dependency on libinput.
INC     := $(shell pkg-config --cflags libinput 2>/dev/null)

TARGET  := libenable-3fg-drag.so
SRC     := enable-3fg-drag.c

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) $(INC) $(LDFLAGS) -o $@ $< -ldl

clean:
	rm -f $(TARGET)

.PHONY: clean
