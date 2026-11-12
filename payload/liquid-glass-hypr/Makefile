# liquid-glass-hypr — real-time liquid glass, rendered in the compositor.
#
# shaders/*.frag are the source of truth; embed.py bakes them into
# src/Shaders.hpp (build output, not committed) before compiling.

CXX ?= g++
CXXFLAGS = -fPIC -g -O2 -std=c++23
# Plugins live in $HOME but link against 0.57 libs in /usr/local/lib
# (aquamarine .15, hyprland's own deps). Bake that dir into RUNPATH so the
# plugin loads regardless of the host's loader scope.
RPATH = $(shell pkg-config --libs-only-L hyprland 2>/dev/null | sed 's/^-L//; s/ -L/:/g')
LDFLAGS = -shared
ifneq ($(strip $(RPATH)),)
LDFLAGS += -Wl,-rpath,$(RPATH)
endif
INCLUDES = $(shell pkg-config --cflags hyprland pixman-1 libdrm)
LIBS = $(shell pkg-config --libs hyprland) $(shell pkg-config --libs libpng)

ifeq ($(basename $(CXX)),g++)
	CXXFLAGS += --no-gnu-unique
endif

TARGET = liquidglass.so
SOURCES = src/main.cpp src/Config.cpp src/Glass.cpp src/GlassPass.cpp src/BorderGlass.cpp src/WindowGlass.cpp src/BlendPass.cpp src/WindowWash.cpp
HEADERS = src/Config.hpp src/Glass.hpp src/GlassPass.hpp src/BorderGlass.hpp src/WindowGlass.hpp src/BlendPass.hpp src/WindowWash.hpp src/RenderCtx.hpp src/GooStub.hpp
OBJ = $(SOURCES:.cpp=.o)

all: $(TARGET)

src/Shaders.hpp: shaders/glass.frag shaders/kawase_down.frag shaders/kawase_up.frag shaders/bokeh.frag shaders/ring.frag shaders/blend.frag shaders/wash.frag shaders/glass.vert embed.py
	python3 embed.py

%.o : %.cpp src/Shaders.hpp $(HEADERS)
	@echo "[$(CXX)] $<"
	@$(CXX) -c $(CXXFLAGS) $(INCLUDES) $< -o $@

$(TARGET): $(OBJ)
	@echo "Linking $(TARGET)..."
	@$(CXX) $(LDFLAGS) $(OBJ) -o $@ $(LIBS)
	@echo "Done!"

clean:
	rm -f $(OBJ) $(TARGET) src/Shaders.hpp

.PHONY: all clean
