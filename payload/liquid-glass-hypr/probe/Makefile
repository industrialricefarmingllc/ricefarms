CXX ?= g++
CXXFLAGS ?= -std=c++2b -fPIC -shared -Wall -Wno-missing-braces \
  $(shell pkg-config --cflags hyprland 2>/dev/null) -O2
LIBS = $(shell pkg-config --libs hyprland 2>/dev/null)

all: lgprobe.so

lgprobe.so: probe.cpp
	@$(CXX) $(CXXFLAGS) $< -o $@ $(LIBS)
	@echo "Done!"

clean:
	rm -f lgprobe.so
