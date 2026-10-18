# hypr-goo-workspaces — gooey workspace-switch window animations.
#
# Pure geometry plugin (no shaders in v1): hooks renderWindow and drives its
# own per-monitor transition. Same toolchain pattern as liquid-glass-hypr.

CXX ?= g++
CXXFLAGS = -fPIC -g -O2 -std=c++23 -Wall -Wextra
LDFLAGS = -shared
INCLUDES = $(shell pkg-config --cflags hyprland pixman-1 libdrm)
LIBS = $(shell pkg-config --libs hyprland)

ifeq ($(basename $(CXX)),g++)
	CXXFLAGS += --no-gnu-unique
endif

TARGET = gooworkspaces.so
SOURCES = src/main.cpp src/Config.cpp src/GooTransition.cpp src/GooPass.cpp
HEADERS = src/Config.hpp src/GooTransition.hpp src/GooPass.hpp
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
