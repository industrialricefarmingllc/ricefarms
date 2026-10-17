. "$HOME/.cargo/env"

# Steam/NVIDIA shader cache persistence: stop driver pruning its on-disk
# pipeline cache on every launch (forces Steam fossilize + in-game recompile).
export __GL_SHADER_DISK_CACHE_SIZE=1073741824
export __GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1
export MESA_SHADER_CACHE_MAX_SIZE=2G
