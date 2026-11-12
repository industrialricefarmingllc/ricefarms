#!/bin/sh
# Shared yt-dlp launcher for the ambience scripts.
#
# YouTube often answers an anonymous extractor with "Sign in to confirm you're
# not a bot", and then no stream ever starts. A browser profile that has been
# used on YouTube carries the cookies that pass that check, so find the first
# Chromium-family profile with a cookie database.
#
# AMBIENCE_BROWSER can name another yt-dlp browser spec, for example
# "firefox" or "chromium:/path/to/profile". AMBIENCE_COOKIES can point at an
# exported Netscape cookie file instead.

ambience_cookie_source() {
    if [ -n "${AMBIENCE_BROWSER:-}" ]; then
        printf '%s\n' "$AMBIENCE_BROWSER"
        return 0
    fi

    for dir in \
        "$HOME/.config/net.imput.helium" \
        "$HOME/.config/helium" \
        "$HOME/.config/chromium" \
        "$HOME/.config/google-chrome" \
        "$HOME/.config/BraveSoftware/Brave-Browser" \
        "$HOME/.config/microsoft-edge" \
        "$HOME/.config/vivaldi" \
        "$HOME/.config/thorium"; do
        if [ -f "$dir/Default/Cookies" ]; then
            printf 'chromium:%s\n' "$dir"
            return 0
        fi
    done
    return 1
}

ambience_ytdlp() {
    if [ -n "${AMBIENCE_COOKIES:-}" ] && [ -f "$AMBIENCE_COOKIES" ]; then
        yt-dlp --cookies "$AMBIENCE_COOKIES" "$@"
        return $?
    fi

    source=$(ambience_cookie_source)
    if [ -n "$source" ]; then
        yt-dlp --cookies-from-browser "$source" "$@"
    else
        yt-dlp "$@"
    fi
}
