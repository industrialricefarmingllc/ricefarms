# --- tmux continuum/resurrect: restore on boot instead of blank new-session ---
# Previous `tmux new-session -A -s main` raced continuum's restore-on-start,
# creating an empty `main` before resurrect could restore the saved layout
# (saves are in ~/.local/share/tmux/resurrect/). Fix: start server with
# exit-empty off, allow continuum 1.5s, then fall back to synchronous resurrect.
if [ -z "$TMUX" ] && [ -z "$KITTY_WINDOW_ID" ] && [ "$TERM" != "xterm-kitty" ] && [ -z "$NO_TMUX" ]; then
  # Kitty is explicitly excluded (KITTY_WINDOW_ID/TERM/NO_TMUX guard — see kitty.conf: env NO_TMUX=1)
  if ! tmux has-session 2>/dev/null; then
    tmux start-server 2>/dev/null
    # If server has no sessions but is running (exit-empty off), let continuum restore
    if tmux ls 2>&1 | grep -q "no server"; then
      # Server died (exit-empty on) - create dummy, restore synchronously
      if [ -f "$HOME/.local/share/tmux/resurrect/last" ] && [ -x "$HOME/.tmux/plugins/tmux-resurrect/scripts/restore.sh" ]; then
        tmux new-session -d -s __restore_dummy 2>/dev/null || true
        "$HOME/.tmux/plugins/tmux-resurrect/scripts/restore.sh" 2>/dev/null || true
        sleep 0.5
        tmux kill-session -t __restore_dummy 2>/dev/null || true
      else
        sleep 1.0
      fi
    else
      # Server running - continuum's background restore sleeps 1s, wait 1.5s
      sleep 1.5
      # If still no session, try synchronous restore as fallback
      if ! tmux has-session 2>/dev/null && [ -x "$HOME/.tmux/plugins/tmux-resurrect/scripts/restore.sh" ]; then
        "$HOME/.tmux/plugins/tmux-resurrect/scripts/restore.sh" 2>/dev/null || true
        sleep 0.5
      fi
    fi
  fi
  if tmux has-session -t main 2>/dev/null; then
    # Fix multi-client overflow: 213x60 (tty3) vs 213x53 (pts/0) vs 139x28 (konsole)
    # sharing `main` with `window-size latest` caused 7-row overflow.
    # Use per-TTY grouped session so each terminal tracks its own active window,
    # plus `window-size smallest` in tmux.conf ensures no overflow (large gets letterbox).
    _tmux_tty_raw=$(tty 2>/dev/null)
    _tmux_sess="main"
    case "$_tmux_tty_raw" in
      /dev/*) _tmux_tty=$(echo "$_tmux_tty_raw" | sed 's|/dev/||; s|/|_|g'); _tmux_sess="main_$_tmux_tty" ;;
    esac
    if [ "$_tmux_sess" != "main" ]; then
      tmux new-session -d -t main -s "$_tmux_sess" 2>/dev/null || true
      tmux attach -t "$_tmux_sess" \; run-shell 'tmux resize-window -a 2>/dev/null || true' 2>/dev/null || tmux attach -t main
    else
      tmux attach -t main \; run-shell 'tmux resize-window -a 2>/dev/null || true' 2>/dev/null || tmux attach -t main
    fi
    unset _tmux_tty_raw _tmux_tty _tmux_sess
  elif tmux has-session 2>/dev/null; then
    tmux attach \; run-shell 'tmux resize-window -a 2>/dev/null || true' 2>/dev/null || tmux attach
  else
    tmux new-session -s main
  fi
fi

# If you come from bash you might have to change your $PATH.
export PATH=$HOME/bin:$HOME/.local/bin:/usr/local/bin:$PATH
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# Path to your Oh My Zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# Set name of the theme to load --- if set to "random", it will
# load a random theme each time Oh My Zsh is loaded, in which case,
# to know which specific one was loaded, run: echo $RANDOM_THEME
# See https://github.com/ohmyzsh/ohmyzsh/wiki/Themes
#ZSH_THEME="robbyrussell"
ZSH_THEME="afowler"

# Set list of themes to pick from when loading at random
# Setting this variable when ZSH_THEME=random will cause zsh to load
# a theme from this variable instead of looking in $ZSH/themes/
# If set to an empty array, this variable will have no effect.
# ZSH_THEME_RANDOM_CANDIDATES=( "robbyrussell" "agnoster" )

# Uncomment the following line to use case-sensitive completion.
# CASE_SENSITIVE="true"

# Uncomment the following line to use hyphen-insensitive completion.
# Case-sensitive completion must be off. _ and - will be interchangeable.
# HYPHEN_INSENSITIVE="true"

# Uncomment one of the following lines to change the auto-update behavior
# zstyle ':omz:update' mode disabled  # disable automatic updates
# zstyle ':omz:update' mode auto      # update automatically without asking
# zstyle ':omz:update' mode reminder  # just remind me to update when it's time

# Uncomment the following line to change how often to auto-update (in days).
# zstyle ':omz:update' frequency 13

# Uncomment the following line if pasting URLs and other text is messed up.
# DISABLE_MAGIC_FUNCTIONS="true"

# Uncomment the following line to disable colors in ls.
# DISABLE_LS_COLORS="true"

# Uncomment the following line to disable auto-setting terminal title.
# DISABLE_AUTO_TITLE="true"

# Uncomment the following line to enable command auto-correction.
# ENABLE_CORRECTION="true"

# Uncomment the following line to display red dots whilst waiting for completion.
# You can also set it to another string to have that shown instead of the default red dots.
# e.g. COMPLETION_WAITING_DOTS="%F{yellow}waiting...%f"
# Caution: this setting can cause issues with multiline prompts in zsh < 5.7.1 (see #5765)
# COMPLETION_WAITING_DOTS="true"

# Uncomment the following line if you want to disable marking untracked files
# under VCS as dirty. This makes repository status check for large repositories
# much, much faster.
# DISABLE_UNTRACKED_FILES_DIRTY="true"

# Uncomment the following line if you want to change the command execution time
# stamp shown in the history command output.
# You can set one of the optional three formats:
# "mm/dd/yyyy"|"dd.mm.yyyy"|"yyyy-mm-dd"
# or set a custom format using the strftime function format specifications,
# see 'man strftime' for details.
# HIST_STAMPS="mm/dd/yyyy"

# Would you like to use another custom folder than $ZSH/custom?
# ZSH_CUSTOM=/path/to/new-custom-folder

# Which plugins would you like to load?
# Standard plugins can be found in $ZSH/plugins/
# Custom plugins may be added to $ZSH_CUSTOM/plugins/
# Example format: plugins=(rails git textmate ruby lighthouse)
# Add wisely, as too many plugins slow down shell startup.
plugins=(git)

source $ZSH/oh-my-zsh.sh

# User configuration

# export MANPATH="/usr/local/man:$MANPATH"

# You may need to manually set your language environment
# export LANG=en_US.UTF-8

# Preferred editor for local and remote sessions
# if [[ -n $SSH_CONNECTION ]]; then
#   export EDITOR='vim'
# else
#   export EDITOR='mvim'
# fi

# Compilation flags
# export ARCHFLAGS="-arch $(uname -m)"

# Set personal aliases, overriding those provided by Oh My Zsh libs,
# plugins, and themes. Aliases can be placed here, though Oh My Zsh
# users are encouraged to define aliases within a top-level file in
# the $ZSH_CUSTOM folder, with .zsh extension. Examples:
# - $ZSH_CUSTOM/aliases.zsh
# - $ZSH_CUSTOM/macos.zsh
# For a full list of active aliases, run `alias`.
#
# Example aliases
# alias zshconfig="mate ~/.zshrc"
# alias ohmyzsh="mate ~/.oh-my-zsh"
# Aliases
alias rep="~/rep.sh"
alias r="~/r.sh"
alias l="~/l.sh"
alias ll="~/ll.sh"
alias rr="~/rr.sh"
alias enter="~/enter.sh"
alias rmpg="~/rmpg.sh"
alias rmi="~/rmi.sh"
alias reload="source ~/.bashrc"
alias bashrc="nano ~/.bashrc && reload"
alias workenv=". ~/workenv.sh"
alias rmc="~/rmc.sh"
alias di="~/di.sh"
alias moirai="~/moirai.sh"
alias tsm="~/tsm.sh"
alias dc="~/dc.sh"
alias ds="~/ds.sh"
alias rimraf="~/rimraf.sh"
alias rmv="~/rmv.sh"
alias rms="~/rms.sh"
alias dev="~/dev.sh"
alias c="docker-compose"
alias dx="~/dx.sh"
alias cherrysearch="~/cherrysearch.sh"
alias cherrycord="~/cherrycord.sh"
alias post="~/post.sh"
alias genocide="~/genocide.sh"
alias dv="~/dv.sh"
alias dps="~/ps.sh"
alias lsr="~/lsr.sh"
alias lsw="~/lsw.sh"
alias migrate="~/migrate.sh"
alias rmb="~/rmb.sh"
alias f="rg"
alias n="nvim"
alias cp='f(){ mkdir -p "$(dirname "$@: -1")" && command cp "$@"; }; f'
alias comfy="systemctl --user restart comfyui-cu126"

# t: attach to main via per-TTY grouped session (avoids 7-row overflow from tty3 213x60 vs pts/0 213x53)
# Original was: tmux new-session -A -s main (shares windows, latest client wins -> overflow)
t() {
  if [ -n "$TMUX" ]; then echo "already in tmux ($TMUX)"; return 1; fi
  if tmux has-session -t main 2>/dev/null; then
    local _tty_raw=$(tty 2>/dev/null)
    local _sess="main"
    case "$_tty_raw" in
      /dev/*) local _tty=$(echo "$_tty_raw" | sed 's|/dev/||; s|/|_|g'); _sess="main_$_tty" ;;
    esac
    if [ "$_sess" != "main" ]; then
      tmux new-session -d -t main -s "$_sess" 2>/dev/null || true
      tmux attach -t "$_sess" \; run-shell 'tmux resize-window -a 2>/dev/null || true' 2>/dev/null || tmux attach -t main
    else
      tmux new-session -A -s main \; run-shell 'tmux resize-window -a 2>/dev/null || true' 2>/dev/null || tmux attach -t main
    fi
  else
    tmux new-session -A -s main
  fi
}
alias dt="ctop"
alias lint="~/lint.sh"
alias buildable="~/buildable.sh"
alias own="~/own.sh"
alias x="~/x.sh"
alias ci="~/ci.sh"
alias push="~/push.sh"
alias cdir="source ~/cdir.sh"
alias amend="~/amend.sh"
alias o="opencode"
alias ca='noglob ca'
alias carbonyl='noglob carbonyl'
alias cup="~/cup.sh"
alias cr="~/cr.sh"
alias restore="~/restore.sh"
alias commit="~/commit.sh"
alias tree="git log --oneline --graph --decorate --all"
alias warp="~/warp.sh"
alias tun="~/tun.sh"
alias cc="concision check"
alias f="~/f.sh"
alias sw="/home/nicerice/sw.sh"
alias windows="~/windows.sh"
alias fw="~/fw.sh"
alias sesh="~/se.sh"

w() {
  local output dir
  output=$(~/wt.sh "$@")
  local ret=$?
  if [[ $ret -ne 0 ]]; then
    echo "$output"
    return $ret
  fi
  dir=$(echo "$output" | sed -n 's/^__WT_CD__://p')
  if [[ -n "$dir" ]]; then
    # print everything except the marker line
    echo "$output" | sed '/^__WT_CD__:/d'
    cd "$dir"
  else
    echo "$output"
  fi
}

# Defaults
workenv occure

# bun completions
[ -s "$HOME/.bun/_bun" ] && source "$HOME/.bun/_bun"

# z
if command -v zoxide >/dev/null 2>&1; then eval "$(zoxide init zsh)"; fi

# tmux
#if [[ -n $PS1 ]] && command -v tmux &> /dev/null && [ -z "$TMUX" ]; then
#  tmux attach-session -t default || tmux new-session -s default
#fi

# set tab/title to the full command before execution
autoload -Uz add-zsh-hook

_preexec_set_title() {
  # $1 is the command line about to run
  printf '\033]0;%s\007' "$1"
}

add-zsh-hook preexec _preexec_set_title
export PATH=$HOME/.local/bin:$PATH

# disable ctrl z suspensions
stty susp undef

# >>> flywheel PATH >>>
if ! printf "%s" ":$PATH:" | grep -F -q ":$HOME/.local/bin:"; then
  export PATH="$HOME/.local/bin:$PATH"
fi
# <<< flywheel PATH <<<

# opencode
export PATH=$HOME/.opencode/bin:$PATH
export OPENCODE_FAST_BOOT=1
alias coa='noglob ca'

# cargo
export PATH="$HOME/nicerice/.cargo/bin:$PATH"

# Remote-nvim without nesting: attach THIS terminal straight to the dev box
# as a full-screen remote UI. No popup, no extra Kitty window.
# Usage: rdev [host] (default: dev) | rdev-stop [host] (kill server+tunnel)
rdev() {
  local host="${1:-dev}"
  local rsock="/tmp/nvim-remote.sock"
  local lsock="/tmp/nvim-remote-${host}.sock"
  command -v nvim >/dev/null || { echo "rdev: local nvim missing"; return 1; }
  local rnvim
  rnvim=$(ssh -o BatchMode=yes "$host" 'ls -d ~/.remote-nvim/nvim-downloads/*/bin/nvim 2>/dev/null | sort -V | tail -1') || return 1
  [ -n "$rnvim" ] || { echo "rdev: no remote nvim found for $host"; return 1; }
  # reuse living server, else start one detached (survives ssh exit via setsid)
  if ! ssh -o BatchMode=yes "$host" "$rnvim --server $rsock --remote-expr 1+1 2>/dev/null" 2>/dev/null | grep -q '^2$'; then
    ssh "$host" "rm -f $rsock; setsid $rnvim --headless --listen $rsock >/dev/null 2>&1 < /dev/null &"
    local i
    for i in $(seq 1 20); do
      ssh -o BatchMode=yes "$host" "$rnvim --server $rsock --remote-expr 1+1 2>/dev/null" 2>/dev/null | grep -q '^2$' && break
      sleep 0.5
    done
  fi
  # fresh tunnel (drop any stale one first)
  pkill -f "ssh -fN -L $lsock" 2>/dev/null
  rm -f "$lsock"
  ssh -fN -L "$lsock:$rsock" "$host" || return 1
  local i
  for i in $(seq 1 20); do [ -S "$lsock" ] && break; sleep 0.5; done
  nvim --server "$lsock" --remote-ui
}

rdev-stop() {
  local host="${1:-dev}"
  local rsock="/tmp/nvim-remote.sock"
  local lsock="/tmp/nvim-remote-${host}.sock"
  ssh -o BatchMode=yes "$host" "pkill -f 'nvim --headless --listen $rsock'; rm -f $rsock" 2>/dev/null
  pkill -f "ssh -fN -L $lsock" 2>/dev/null
  rm -f "$lsock"
  echo "rdev: $host stopped"
}

# pnpm
export PNPM_HOME='/home/nicerice/.local/share/pnpm'
case ":$PATH:" in
  *":$PNPM_HOME/bin:"*) ;;
  *) export PATH="$PNPM_HOME/bin:$PATH" ;;
esac
# pnpm end

# --- matugen auto-resync on ssh dev (non-blocking) ---
# Pushes the local matugen palette/theme in the BACKGROUND so connects stay
# instant (~0ms added: just spawns nohup + watcher-ensure, then connects).
# The background job (~/matugen-sync-dev.sh --background):
#   - skips when sources aren't newer than ~/.cache/matugen-sync-dev.last,
#   - collapses concurrent runs via flock,
#   - uploads in 1 tar pipe + 1 remote step (multiplexed, ~0.5s total),
#   - applies the palette to THIS terminal immediately via OSC (SYNC_TTY),
#     so live changes show with no reconnect. Remote opencode reloads
#     matugen.json via its tui-matugen-live.ts watcher, also no reconnect.
# Plus ~/matugen-watch-dev.sh (started here, singleton daemon) keeps pushing
# subsequent wallpaper/theme changes in real time for the whole session.
# Sync failures only land in ~/.cache/matugen-sync-dev*.log, never block.
# (The sync script's own ssh calls run in child processes that never see
# these functions, plus MATUGEN_SYNC_IN_PROGRESS guards sourced runs.)
_matugen_sync_bg() {
  case "$TERM" in
    xterm-kitty) ;;
    *) echo "matugen: WARNING: local TERM=$TERM (not xterm-kitty) - remote will be 256-color quantized" ;;
  esac
  if [ -x "$HOME/matugen-sync-dev.sh" ]; then
    local _tty
    _tty="$(tty 2>/dev/null || true)"
    SYNC_TTY="$_tty" nohup "$HOME/matugen-sync-dev.sh" --background >>"$HOME/.cache/matugen-sync-dev.log" 2>&1 &!
  fi
  if [ -x "$HOME/matugen-watch-dev.sh" ]; then
    ("$HOME/matugen-watch-dev.sh" --ensure >>"$HOME/.cache/matugen-sync-dev-watch.log" 2>&1 &!) 2>/dev/null
  fi
}
ssh() {
  local _m_do_sync=
  if [ -z "$MATUGEN_SYNC_IN_PROGRESS" ]; then
    local _a
    for _a in "$@"; do
      case "$_a" in
        dev|*@dev) _m_do_sync=1; break ;;
      esac
    done
  fi
  [ -n "$_m_do_sync" ] && _matugen_sync_bg
  unset _m_do_sync _a
  command ssh "$@"
}
# d replaces the old `alias d=~/d.sh`: same dev helper, but kicks a
# background matugen sync first (covers the mosh path, which plain
# `ssh dev` never sees). Connection starts immediately; sync lands ~0.5s
# later with no reconnect needed.
d() {
  _matugen_sync_bg
  "$HOME/d.sh" "$@"
}

export PATH="$HOME/.pyenv/bin:$PATH"
eval "$(pyenv init -)"
