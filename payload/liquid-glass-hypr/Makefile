# liquid-glass-hypr — real-time liquid glass, rendered in the compositor.
#
# shaders/*.frag are the source of truth; embed.py bakes them into
# src/Shaders.hpp (build output, not committed) before compiling.

CXX ?= g++
CXXFLAGS = -fPIC -g -O2 -std=c++23
LDFLAGS = -shared
INCLUDES = $(shell pkg-config --cflags hyprland pixman-1 libdrm)
LIBS = $(shell pkg-config --libs hyprland)

ifeq ($(basename $(CXX)),g++)
	CXXFLAGS += --no-gnu-unique
endif

TARGET = liquidglass.so
SOURCES = src/main.cpp src/Config.cpp src/Glass.cpp src/GlassPass.cpp src/BorderGlass.cpp src/WindowGlass.cpp src/GooConfig.cpp src/GooMorph.cpp src/GooPass.cpp src/GooTransition.cpp
HEADERS = src/Config.hpp src/Glass.hpp src/GlassPass.hpp src/BorderGlass.hpp src/WindowGlass.hpp src/GooConfig.hpp src/GooMorph.hpp src/GooPass.hpp src/GooTransition.hpp
OBJ = $(SOURCES:.cpp=.o)

all: $(TARGET)

src/Shaders.hpp: shaders/glass.frag shaders/kawase_down.frag shaders/kawase_up.frag shaders/bokeh.frag shaders/ring.frag shaders/glass.vert embed.py
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
