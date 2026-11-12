# hypr-edge-swipe — touch edge-swipe workspace navigation.
#
# Hyprland's built-in gestures:workspace_swipe_touch refuses to begin when
# the touch lands on a layer surface above the bottom layer (Touch.cpp's
# m_foundLSToFocus <= 1 check). A shell with permanent fullscreen top or
# overlay surfaces (quickshell panels, decorative overlays) therefore can
# never trigger it. This plugin listens on the input.touch event bus
# instead. Same toolchain pattern as liquid-glass-hypr / hypr-goo-workspaces.

CXX ?= g++
CXXFLAGS = -fPIC -g -O2 -std=c++23 -Wall -Wextra
# Plugins live in $HOME but link against 0.57 libs in /usr/local/lib
# (aquamarine .15, hyprland's own deps). Bake that dir into RUNPATH so the
# plugin loads regardless of the host's loader scope.
RPATH = $(shell pkg-config --libs-only-L hyprland 2>/dev/null | sed 's/^-L//; s/ -L/:/g')
LDFLAGS = -shared
ifneq ($(strip $(RPATH)),)
LDFLAGS += -Wl,-rpath,$(RPATH)
endif
INCLUDES = $(shell pkg-config --cflags hyprland pixman-1 libdrm)
LIBS = $(shell pkg-config --libs hyprland)

ifeq ($(basename $(CXX)),g++)
	CXXFLAGS += --no-gnu-unique
endif

TARGET = hypr-touch-gestures.so
SOURCES = src/main.cpp src/Config.cpp
HEADERS = src/Config.hpp
OBJ = $(SOURCES:.cpp=.o)

all: $(TARGET)

%.o : %.cpp $(HEADERS)
	@echo "[$(CXX)] $<"
	@$(CXX) -c $(CXXFLAGS) $(INCLUDES) $< -o $@

$(TARGET): $(OBJ)
	@echo "Linking $(TARGET)..."
	@$(CXX) $(LDFLAGS) $(OBJ) -o $@ $(LIBS)
	@echo "Done!"

clean:
	rm -f $(OBJ) $(TARGET)

.PHONY: all clean
