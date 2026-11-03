# lucidcap — workspace-capture recorder for Hyprland (LucidShot backend)
#
# Captures the active workspace on one output through Hyprland's
# hyprland_workspace_image_capture_source_v1 + ext_image_copy_capture_v1,
# so layers marked `no_screen_share` (the capture toolbar) stay on screen
# but are left out of the video. Frames go to a child ffmpeg as raw BGRA.

CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra -Wno-unused-parameter
PKGS     = wayland-client
CFLAGS  += $(shell pkg-config --cflags $(PKGS))
LDLIBS  += $(shell pkg-config --libs $(PKGS))

PROTO_DIR = protocols
GEN_DIR   = gen
PROTOCOLS = ext-workspace-v1 \
            ext-image-copy-capture-v1 \
            ext-image-capture-source-v1 \
            ext-foreign-toplevel-list-v1 \
            hyprland-workspace-image-capture-source-v1

GEN_C   = $(foreach p,$(PROTOCOLS),$(GEN_DIR)/$(p)-protocol.c)
GEN_H   = $(foreach p,$(PROTOCOLS),$(GEN_DIR)/$(p)-client-protocol.h)
XML     = $(foreach p,$(PROTOCOLS),$(PROTO_DIR)/$(p).xml)

PREFIX  ?= $(HOME)/.local
BIN      = lucidcap

all: $(BIN)

$(GEN_DIR):
	mkdir -p $(GEN_DIR)

$(GEN_DIR)/%-client-protocol.h: $(PROTO_DIR)/%.xml | $(GEN_DIR)
	wayland-scanner client-header $< $@

$(GEN_DIR)/%-protocol.c: $(PROTO_DIR)/%.xml | $(GEN_DIR)
	wayland-scanner private-code $< $@

$(BIN): lucidcap.c $(GEN_C) $(GEN_H)
	$(CC) $(CFLAGS) -I$(GEN_DIR) -o $@ lucidcap.c $(GEN_C) $(LDLIBS)

install: $(BIN)
	install -d $(PREFIX)/bin
	install -m 755 $(BIN) $(PREFIX)/bin/$(BIN)

clean:
	rm -rf $(GEN_DIR) $(BIN)

.PHONY: all install clean
