/*
 * lucidcap — a workspace-capture recorder for Hyprland.
 *
 * Why this exists: wf-recorder (and grim) use wlr-screencopy, where the
 * compositor blits the already-composited monitor texture. Anything visible
 * on screen is therefore in the frame, and Hyprland's `no_screen_share`
 * paints black boxes over flagged surfaces. The workspace capture path
 * (hyprland_workspace_image_capture_source_v1 + ext_image_copy_capture_v1)
 * re-renders the scene with the capture flag set, so `no_screen_share`
 * layers are skipped entirely instead of blacked out. That lets the
 * LucidShot toolbar stay on screen while staying out of the video.
 *
 * Frames are read as shm BGRA and piped to a child ffmpeg, which also
 * records the PulseAudio monitor the shell already mixes for the mic.
 *
 * SPDX-License-Identifier: MIT
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <wayland-client.h>

#include "ext-image-capture-source-v1-client-protocol.h"
#include "ext-image-copy-capture-v1-client-protocol.h"
#include "ext-workspace-v1-client-protocol.h"
#include "hyprland-workspace-image-capture-source-v1-client-protocol.h"

/* ------------------------------------------------------------------ */
/* options                                                            */

static const char *opt_monitor   = NULL;
static const char *opt_output    = NULL;
static const char *opt_audio     = NULL;
static const char *opt_device    = NULL;
static const char *opt_encoder   = "libx264";
static int         opt_fps       = 30;
static int         opt_frames    = 0; /* 0 = until signalled */
static bool        opt_list      = false;
static bool        opt_quiet     = false;
static int         opt_crop_x = -1, opt_crop_y = -1, opt_crop_w = 0, opt_crop_h = 0;
static int         opt_logical_w = 0, opt_logical_h = 0;

/* ------------------------------------------------------------------ */
/* wayland state                                                      */

static struct wl_display                                        *display;
static struct wl_registry                                       *registry;
static struct wl_shm                                            *shm;
static struct ext_workspace_manager_v1                          *ws_manager;
static struct hyprland_workspace_image_capture_source_manager_v1 *ws_source_manager;
static struct ext_image_copy_capture_manager_v1                 *capture_manager;

struct output {
    struct wl_output *obj;
    char              name[64];
    bool              named;
    struct wl_list    link;
};

struct ws_group {
    struct ext_workspace_group_handle_v1 *obj;
    struct wl_output                     *outputs[16];
    int                                   noutputs;
    struct ws                            *workspaces[64];
    int                                   nworkspaces;
    struct wl_list                        link;
};

struct ws {
    struct ext_workspace_handle_v1 *obj;
    char                            name[128];
    uint32_t                        state;
    struct ws_group                *group;
    struct wl_list                  link;
};

static struct wl_list outputs;      /* struct output */
static struct wl_list groups;       /* struct ws_group */
static struct wl_list workspaces;   /* struct ws */

static struct output *target_output;
static struct ws     *current_ws;

/* capture */
static struct ext_image_capture_source_v1       *capture_source;
static struct ext_image_copy_capture_session_v1 *capture_session;
static struct ext_image_copy_capture_frame_v1   *capture_frame;

static struct wl_shm_pool *shm_pool;
static struct wl_buffer   *shm_buffer;
static uint8_t            *shm_data;
static size_t              shm_size;

static uint32_t buf_w, buf_h;
static bool     have_size, have_format;
static bool     frame_inflight;

static int stream_w, stream_h; /* buffer size the encoder was started for */
static int out_x, out_y, out_w, out_h; /* crop in buffer pixels */

/* pacing */
static long long t_start_ms;
static long long frames_written;
static long long frame_limit;

/* ffmpeg */
static int   ffmpeg_fd = -1;
static pid_t ffmpeg_pid = -1;
static bool  encoder_started;

/* run state */
enum phase {
    PHASE_WAIT_WORKSPACES,
    PHASE_WAIT_CONSTRAINTS,
    PHASE_RUNNING,
};
static enum phase            phase = PHASE_WAIT_WORKSPACES;
static volatile sig_atomic_t running = 1;
static int                   exit_code = 0;

static void logmsg(const char *fmt, ...) {
    if (opt_quiet)
        return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* ------------------------------------------------------------------ */
/* registry                                                           */

static void output_geometry(void *data, struct wl_output *o, int32_t x, int32_t y, int32_t pw, int32_t ph, int32_t subpixel,
                            const char *make, const char *model, int32_t transform) {}

static void output_mode(void *data, struct wl_output *o, uint32_t flags, int32_t w, int32_t h, int32_t refresh) {}

static void output_done(void *data, struct wl_output *o) {}

static void output_scale(void *data, struct wl_output *o, int32_t factor) {}

static void output_name(void *data, struct wl_output *o, const char *name) {
    struct output *out = data;
    snprintf(out->name, sizeof out->name, "%s", name ? name : "");
    out->named = true;
}

static void output_description(void *data, struct wl_output *o, const char *d) {}

static const struct wl_output_listener output_listener = {
    .geometry    = output_geometry,
    .mode        = output_mode,
    .done        = output_done,
    .scale       = output_scale,
    .name        = output_name,
    .description = output_description,
};

/* ------------------------------------------------------------------ */
/* ext_workspace                                                      */

static struct ws *ws_from_handle(struct ext_workspace_handle_v1 *h) {
    struct ws *w;
    wl_list_for_each(w, &workspaces, link) {
        if (w->obj == h)
            return w;
    }
    return NULL;
}

static void group_capabilities(void *data, struct ext_workspace_group_handle_v1 *h, uint32_t caps) {}
static void group_removed(void *data, struct ext_workspace_group_handle_v1 *h) {}

static void group_output_enter(void *data, struct ext_workspace_group_handle_v1 *h, struct wl_output *o) {
    struct ws_group *g = data;
    for (int i = 0; i < g->noutputs; i++) {
        if (g->outputs[i] == o)
            return;
    }
    if (g->noutputs < (int)(sizeof g->outputs / sizeof g->outputs[0]))
        g->outputs[g->noutputs++] = o;
}

static void group_output_leave(void *data, struct ext_workspace_group_handle_v1 *h, struct wl_output *o) {
    struct ws_group *g = data;
    for (int i = 0; i < g->noutputs; i++) {
        if (g->outputs[i] == o) {
            memmove(&g->outputs[i], &g->outputs[i + 1], (g->noutputs - i - 1) * sizeof g->outputs[0]);
            g->noutputs--;
            return;
        }
    }
}

static void group_workspace_enter(void *data, struct ext_workspace_group_handle_v1 *h, struct ext_workspace_handle_v1 *wh) {
    struct ws_group *g  = data;
    struct ws       *ws = ws_from_handle(wh);
    if (!ws || g->nworkspaces >= (int)(sizeof g->workspaces / sizeof g->workspaces[0]))
        return;
    for (int i = 0; i < g->nworkspaces; i++) {
        if (g->workspaces[i] == ws)
            return;
    }
    g->workspaces[g->nworkspaces++] = ws;
    ws->group                       = g;
}

static void group_workspace_leave(void *data, struct ext_workspace_group_handle_v1 *h, struct ext_workspace_handle_v1 *wh) {
    struct ws_group *g  = data;
    struct ws       *ws = ws_from_handle(wh);
    if (!ws)
        return;
    for (int i = 0; i < g->nworkspaces; i++) {
        if (g->workspaces[i] == ws) {
            memmove(&g->workspaces[i], &g->workspaces[i + 1], (g->nworkspaces - i - 1) * sizeof g->workspaces[0]);
            g->nworkspaces--;
            break;
        }
    }
    if (ws->group == g)
        ws->group = NULL;
}

static const struct ext_workspace_group_handle_v1_listener group_listener = {
    .capabilities    = group_capabilities,
    .output_enter    = group_output_enter,
    .output_leave    = group_output_leave,
    .workspace_enter = group_workspace_enter,
    .workspace_leave = group_workspace_leave,
    .removed         = group_removed,
};

static void ws_id(void *data, struct ext_workspace_handle_v1 *h, const char *id) {}

static void ws_name(void *data, struct ext_workspace_handle_v1 *h, const char *name) {
    struct ws *w = data;
    snprintf(w->name, sizeof w->name, "%s", name ? name : "");
}

static void ws_coordinates(void *data, struct ext_workspace_handle_v1 *h, struct wl_array *coords) {}

static void ws_state(void *data, struct ext_workspace_handle_v1 *h, uint32_t state) {
    struct ws *w = data;
    w->state     = state;
}

static void ws_capabilities(void *data, struct ext_workspace_handle_v1 *h, uint32_t caps) {}
static void ws_removed(void *data, struct ext_workspace_handle_v1 *h) {}

static const struct ext_workspace_handle_v1_listener ws_listener = {
    .id           = ws_id,
    .name         = ws_name,
    .coordinates  = ws_coordinates,
    .state        = ws_state,
    .capabilities = ws_capabilities,
    .removed      = ws_removed,
};

/* ------------------------------------------------------------------ */
/* ffmpeg child                                                       */

static int spawn_ffmpeg(int w, int h) {
    int fds[2];
    if (pipe(fds) < 0) {
        logmsg("lucidcap: pipe: %s", strerror(errno));
        return -1;
    }

    char size[64], fps[32];
    snprintf(size, sizeof size, "%dx%d", w, h);
    snprintf(fps, sizeof fps, "%d", opt_fps);

    char *argv[64];
    int   n = 0;
    argv[n++] = "ffmpeg";
    argv[n++] = "-hide_banner";
    argv[n++] = "-loglevel";
    argv[n++] = "error";
    argv[n++] = "-y";
    argv[n++] = "-f";
    argv[n++] = "rawvideo";
    argv[n++] = "-pix_fmt";
    argv[n++] = "bgra";
    argv[n++] = "-s";
    argv[n++] = size;
    argv[n++] = "-r";
    argv[n++] = fps;
    argv[n++] = "-i";
    argv[n++] = "pipe:0";

    if (opt_audio && *opt_audio) {
        argv[n++] = "-f";
        argv[n++] = "pulse";
        argv[n++] = "-i";
        argv[n++] = (char *)opt_audio;
    }

    if (strcmp(opt_encoder, "h264_vaapi") == 0) {
        static char devarg[256];
        snprintf(devarg, sizeof devarg, "vaapi=va:%s", opt_device && *opt_device ? opt_device : "/dev/dri/renderD128");
        argv[n++] = "-init_hw_device";
        argv[n++] = devarg;
        argv[n++] = "-filter_hw_device";
        argv[n++] = "va";
        argv[n++] = "-vf";
        argv[n++] = "format=nv12,hwupload";
        argv[n++] = "-c:v";
        argv[n++] = "h264_vaapi";
        argv[n++] = "-qp";
        argv[n++] = "23";
    } else {
        argv[n++] = "-c:v";
        argv[n++] = "libx264";
        argv[n++] = "-preset";
        argv[n++] = "veryfast";
        argv[n++] = "-crf";
        argv[n++] = "20";
        argv[n++] = "-pix_fmt";
        argv[n++] = "yuv420p";
    }

    if (opt_audio && *opt_audio) {
        argv[n++] = "-c:a";
        argv[n++] = "aac";
        argv[n++] = "-b:a";
        argv[n++] = "192k";
        argv[n++] = "-shortest";
    }

    argv[n++] = (char *)opt_output;
    argv[n++] = NULL;

    pid_t pid = fork();
    if (pid < 0) {
        logmsg("lucidcap: fork: %s", strerror(errno));
        close(fds[0]);
        close(fds[1]);
        return -1;
    }
    if (pid == 0) {
        dup2(fds[0], STDIN_FILENO);
        close(fds[0]);
        close(fds[1]);
        execvp(argv[0], argv);
        _exit(127);
    }

    close(fds[0]);
    ffmpeg_pid = pid;
    return fds[1];
}

static void finish(void) {
    if (ffmpeg_fd >= 0) {
        close(ffmpeg_fd);
        ffmpeg_fd = -1;
    }
    if (ffmpeg_pid > 0) {
        int status = 0;
        while (waitpid(ffmpeg_pid, &status, 0) < 0 && errno == EINTR) {
        }
        if (WIFEXITED(status) && WEXITSTATUS(status) != 0)
            exit_code = WEXITSTATUS(status);
        else if (WIFSIGNALED(status))
            exit_code = 1;
        ffmpeg_pid = -1;
    }
}

static bool write_all(const void *buf, size_t len) {
    const uint8_t *p = buf;
    while (len > 0) {
        ssize_t n = write(ffmpeg_fd, p, len);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            if (errno == EPIPE) {
                logmsg("lucidcap: ffmpeg closed the pipe");
                exit_code = 1;
                running   = 0;
                return false;
            }
            logmsg("lucidcap: write: %s", strerror(errno));
            exit_code = 1;
            running   = 0;
            return false;
        }
        p += n;
        len -= (size_t)n;
    }
    return true;
}

static bool emit_frame(void) {
    if (!shm_data)
        return false;

    const size_t stride = (size_t)buf_w * 4;
    if (out_x == 0 && out_w == (int)buf_w) {
        if (!write_all(shm_data + (size_t)out_y * stride, (size_t)out_w * out_h * 4))
            return false;
    } else {
        const size_t row = (size_t)out_w * 4;
        for (int y = 0; y < out_h; y++) {
            const uint8_t *src = shm_data + (size_t)(out_y + y) * stride + (size_t)out_x * 4;
            if (!write_all(src, row))
                return false;
        }
    }
    frames_written++;
    return true;
}

/* ------------------------------------------------------------------ */
/* capture session                                                    */

static void compute_crop(void) {
    out_x = 0;
    out_y = 0;
    out_w = (int)buf_w;
    out_h = (int)buf_h;

    if (opt_crop_w > 0 && opt_crop_h > 0 && opt_logical_w > 0 && opt_logical_h > 0) {
        const double sx = (double)buf_w / (double)opt_logical_w;
        const double sy = (double)buf_h / (double)opt_logical_h;
        int          x  = (int)((double)opt_crop_x * sx + 0.5);
        int          y  = (int)((double)opt_crop_y * sy + 0.5);
        int          w  = (int)((double)opt_crop_w * sx + 0.5);
        int          h  = (int)((double)opt_crop_h * sy + 0.5);

        if (x < 0)
            x = 0;
        if (y < 0)
            y = 0;
        if (w > (int)buf_w - x)
            w = (int)buf_w - x;
        if (h > (int)buf_h - y)
            h = (int)buf_h - y;
        w &= ~1;
        h &= ~1;
        if (w > 0 && h > 0) {
            out_x = x;
            out_y = y;
            out_w = w;
            out_h = h;
        }
    }

    /* yuv420p wants even dimensions */
    out_w &= ~1;
    out_h &= ~1;
    if (out_w <= 0)
        out_w = (int)buf_w & ~1;
    if (out_h <= 0)
        out_h = (int)buf_h & ~1;
}

static bool create_buffer(void) {
    if (shm_buffer) {
        wl_buffer_destroy(shm_buffer);
        shm_buffer = NULL;
    }
    if (shm_pool) {
        wl_shm_pool_destroy(shm_pool);
        shm_pool = NULL;
    }
    if (shm_data) {
        munmap(shm_data, shm_size);
        shm_data = NULL;
    }

    shm_size = (size_t)buf_w * buf_h * 4;
    int fd   = memfd_create("lucidcap", MFD_CLOEXEC);
    if (fd < 0) {
        logmsg("lucidcap: memfd_create: %s", strerror(errno));
        return false;
    }
    if (ftruncate(fd, (off_t)shm_size) < 0) {
        logmsg("lucidcap: ftruncate: %s", strerror(errno));
        close(fd);
        return false;
    }
    shm_data = mmap(NULL, shm_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (shm_data == MAP_FAILED) {
        logmsg("lucidcap: mmap: %s", strerror(errno));
        shm_data = NULL;
        close(fd);
        return false;
    }
    shm_pool   = wl_shm_create_pool(shm, fd, (int32_t)shm_size);
    shm_buffer = wl_shm_pool_create_buffer(shm_pool, 0, buf_w, buf_h, (int32_t)buf_w * 4, WL_SHM_FORMAT_ARGB8888);
    close(fd);

    if (!shm_pool || !shm_buffer) {
        logmsg("lucidcap: could not create the shm buffer");
        return false;
    }
    return true;
}

static const struct ext_image_copy_capture_frame_v1_listener frame_listener;

static void start_frame(void) {
    if (frame_inflight || !capture_session || phase != PHASE_RUNNING)
        return;

    capture_frame = ext_image_copy_capture_session_v1_create_frame(capture_session);
    if (!capture_frame)
        return;

    ext_image_copy_capture_frame_v1_attach_buffer(capture_frame, shm_buffer);
    ext_image_copy_capture_frame_v1_add_listener(capture_frame, &frame_listener, NULL);
    ext_image_copy_capture_frame_v1_damage_buffer(capture_frame, 0, 0, (int32_t)buf_w, (int32_t)buf_h);
    ext_image_copy_capture_frame_v1_capture(capture_frame);
    frame_inflight = true;
}

static void frame_ready(void *data, struct ext_image_copy_capture_frame_v1 *f) {
    frame_inflight = false;

    if (!emit_frame()) {
        ext_image_copy_capture_frame_v1_destroy(f);
        capture_frame = NULL;
        return;
    }

    /* if a capture took longer than its slot, repeat the frame so the
     * video keeps the same duration as the audio instead of drifting */
    const long long interval = 1000 / (opt_fps > 0 ? opt_fps : 30);
    int             dups     = 0;
    while (running && dups < 2 && now_ms() > t_start_ms + frames_written * interval + interval) {
        if (!emit_frame())
            break;
        dups++;
    }

    ext_image_copy_capture_frame_v1_destroy(f);
    capture_frame = NULL;

    if (frame_limit > 0 && frames_written >= frame_limit)
        running = 0;
}

static void frame_failed(void *data, struct ext_image_copy_capture_frame_v1 *f, uint32_t reason) {
    frame_inflight = false;
    logmsg("lucidcap: frame failed (%u)", reason);
    exit_code = 1;
    running   = 0;
    ext_image_copy_capture_frame_v1_destroy(f);
    capture_frame = NULL;
}

static void frame_transform(void *data, struct ext_image_copy_capture_frame_v1 *f, uint32_t transform) {
    if (transform != WL_OUTPUT_TRANSFORM_NORMAL)
        logmsg("lucidcap: warning: output transform %u is not applied", transform);
}

static void frame_damage(void *data, struct ext_image_copy_capture_frame_v1 *f, int32_t x, int32_t y, int32_t w, int32_t h) {}

static void frame_presentation_time(void *data, struct ext_image_copy_capture_frame_v1 *f, uint32_t sh, uint32_t sl, uint32_t ns) {}

static const struct ext_image_copy_capture_frame_v1_listener frame_listener = {
    .transform         = frame_transform,
    .damage            = frame_damage,
    .presentation_time = frame_presentation_time,
    .ready             = frame_ready,
    .failed            = frame_failed,
};

static void session_buffer_size(void *data, struct ext_image_copy_capture_session_v1 *s, uint32_t w, uint32_t h) {
    buf_w     = w;
    buf_h     = h;
    have_size = true;
    logmsg("lucidcap: buffer size %ux%u", w, h);
}

static void session_shm_format(void *data, struct ext_image_copy_capture_session_v1 *s, uint32_t format) {
    logmsg("lucidcap: shm format %u", format);
    if (format == WL_SHM_FORMAT_ARGB8888 || format == WL_SHM_FORMAT_XRGB8888)
        have_format = true;
}

static void session_dmabuf_device(void *data, struct ext_image_copy_capture_session_v1 *s, struct wl_array *dev) {}
static void session_dmabuf_format(void *data, struct ext_image_copy_capture_session_v1 *s, uint32_t fmt, struct wl_array *mods) {}

static void session_stopped(void *data, struct ext_image_copy_capture_session_v1 *s) {
    logmsg("lucidcap: the capture session stopped");
    running = 0;
}

static void start_session(struct ws *w);

static void session_done(void *data, struct ext_image_copy_capture_session_v1 *s) {
    if (phase != PHASE_WAIT_CONSTRAINTS)
        return;

    if (!have_size || !have_format) {
        logmsg("lucidcap: the session advertised no usable buffer format");
        exit_code = 1;
        running   = 0;
        return;
    }

    if (!encoder_started) {
        compute_crop();
        if (!create_buffer()) {
            exit_code = 1;
            running   = 0;
            return;
        }
        ffmpeg_fd = spawn_ffmpeg(out_w, out_h);
        if (ffmpeg_fd < 0) {
            exit_code = 1;
            running   = 0;
            return;
        }
        stream_w        = (int)buf_w;
        stream_h        = (int)buf_h;
        encoder_started = true;
        t_start_ms      = now_ms();
        logmsg("lucidcap: capturing workspace '%s' on %s (%dx%d -> %dx%d at %d fps)",
               current_ws ? current_ws->name : "?", target_output ? target_output->name : "?", (int)buf_w, (int)buf_h, out_w, out_h, opt_fps);
    } else if ((int)buf_w != stream_w || (int)buf_h != stream_h) {
        logmsg("lucidcap: the capture size changed to %dx%d; stopping", (int)buf_w, (int)buf_h);
        exit_code = 1;
        running   = 0;
        return;
    }

    phase = PHASE_RUNNING;
    start_frame();
}

static const struct ext_image_copy_capture_session_v1_listener session_listener = {
    .buffer_size   = session_buffer_size,
    .shm_format    = session_shm_format,
    .dmabuf_device = session_dmabuf_device,
    .dmabuf_format = session_dmabuf_format,
    .done          = session_done,
    .stopped       = session_stopped,
};

static void teardown_session(void) {
    if (capture_frame) {
        ext_image_copy_capture_frame_v1_destroy(capture_frame);
        capture_frame = NULL;
    }
    frame_inflight = false;
    if (capture_session) {
        ext_image_copy_capture_session_v1_destroy(capture_session);
        capture_session = NULL;
    }
    if (capture_source) {
        ext_image_capture_source_v1_destroy(capture_source);
        capture_source = NULL;
    }
}

static void start_session(struct ws *w) {
    teardown_session();

    logmsg("lucidcap: starting capture for workspace '%s'", w->name);

    have_size   = false;
    have_format = false;
    current_ws  = w;

    capture_source = hyprland_workspace_image_capture_source_manager_v1_create_source(
        ws_source_manager, w->obj, HYPRLAND_WORKSPACE_IMAGE_CAPTURE_SOURCE_MANAGER_V1_CAPTURE_MODE_EVERYTHING);
    if (!capture_source) {
        logmsg("lucidcap: could not create a capture source for workspace '%s'", w->name);
        exit_code = 1;
        running   = 0;
        return;
    }

    capture_session = ext_image_copy_capture_manager_v1_create_session(capture_manager, capture_source, 0);
    if (!capture_session) {
        logmsg("lucidcap: could not create a capture session");
        exit_code = 1;
        running   = 0;
        return;
    }

    ext_image_copy_capture_session_v1_add_listener(capture_session, &session_listener, NULL);
    phase = PHASE_WAIT_CONSTRAINTS;
}

/* ------------------------------------------------------------------ */
/* workspace selection                                                */

static struct ws *pick_workspace(void) {
    if (!target_output)
        return NULL;

    struct ws_group *g;
    wl_list_for_each(g, &groups, link) {
        bool has = false;
        for (int i = 0; i < g->noutputs; i++) {
            if (g->outputs[i] == target_output->obj) {
                has = true;
                break;
            }
        }
        if (!has)
            continue;

        for (int i = 0; i < g->nworkspaces; i++) {
            struct ws *w = g->workspaces[i];
            if (w->state & EXT_WORKSPACE_HANDLE_V1_STATE_ACTIVE)
                return w;
        }
    }
    return NULL;
}

static void manager_workspace_group(void *data, struct ext_workspace_manager_v1 *m,
                                    struct ext_workspace_group_handle_v1 *h) {
    struct ws_group *g = calloc(1, sizeof *g);
    if (!g)
        return;
    g->obj = h;
    wl_list_insert(&groups, &g->link);
    ext_workspace_group_handle_v1_add_listener(h, &group_listener, g);
}

static void manager_workspace(void *data, struct ext_workspace_manager_v1 *m, struct ext_workspace_handle_v1 *h) {
    struct ws *w = calloc(1, sizeof *w);
    if (!w)
        return;
    w->obj = h;
    wl_list_insert(&workspaces, &w->link);
    ext_workspace_handle_v1_add_listener(h, &ws_listener, w);
}

static void manager_done(void *data, struct ext_workspace_manager_v1 *m) {
    struct ws *w = pick_workspace();

    if (phase == PHASE_WAIT_WORKSPACES) {
        if (!w)
            return; /* wait for the next batch */
        start_session(w);
        return;
    }

    /* follow the active workspace: switching workspaces must not freeze
     * the recording on the one it started on */
    if (w && w != current_ws) {
        logmsg("lucidcap: active workspace is now '%s'", w->name);
        start_session(w);
    }
}

static void manager_finished(void *data, struct ext_workspace_manager_v1 *m) {
    logmsg("lucidcap: the workspace manager finished");
    running = 0;
}

static const struct ext_workspace_manager_v1_listener manager_listener = {
    .workspace_group = manager_workspace_group,
    .workspace       = manager_workspace,
    .done            = manager_done,
    .finished        = manager_finished,
};

/* ------------------------------------------------------------------ */
/* registry                                                           */

static void registry_global(void *data, struct wl_registry *reg, uint32_t name, const char *iface, uint32_t version) {
    if (strcmp(iface, "wl_shm") == 0) {
        shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
    } else if (strcmp(iface, "wl_output") == 0) {
        struct output *out = calloc(1, sizeof *out);
        if (!out)
            return;
        out->obj = wl_registry_bind(reg, name, &wl_output_interface, version < 4 ? version : 4);
        wl_output_add_listener(out->obj, &output_listener, out);
        wl_list_insert(&outputs, &out->link);
    } else if (strcmp(iface, "ext_workspace_manager_v1") == 0) {
        ws_manager = wl_registry_bind(reg, name, &ext_workspace_manager_v1_interface, 1);
        ext_workspace_manager_v1_add_listener(ws_manager, &manager_listener, NULL);
    } else if (strcmp(iface, "hyprland_workspace_image_capture_source_manager_v1") == 0) {
        ws_source_manager = wl_registry_bind(reg, name, &hyprland_workspace_image_capture_source_manager_v1_interface, 1);
    } else if (strcmp(iface, "ext_image_copy_capture_manager_v1") == 0) {
        capture_manager = wl_registry_bind(reg, name, &ext_image_copy_capture_manager_v1_interface, 1);
    }
}

static void registry_global_remove(void *data, struct wl_registry *reg, uint32_t name) {}

static const struct wl_registry_listener registry_listener = {
    .global        = registry_global,
    .global_remove = registry_global_remove,
};

/* ------------------------------------------------------------------ */
/* main                                                               */

static void on_signal(int sig) {
    running = 0;
}

static void usage(FILE *out) {
    fprintf(out,
            "usage: lucidcap --output FILE [options]\n"
            "  --monitor NAME     output to capture (default: first bound output)\n"
            "  --output FILE      video file to write (mp4)\n"
            "  --fps N            frame rate (default 30)\n"
            "  --frames N         stop after N frames (0 = until signalled)\n"
            "  --crop x,y,w,h     crop in logical pixels\n"
            "  --logical WxH      logical size of the monitor (for crop scaling)\n"
            "  --audio DEVICE     PulseAudio source to record (e.g. wfrec_combined.monitor)\n"
            "  --encoder NAME     libx264 (default) or h264_vaapi\n"
            "  --device PATH      DRM render node for h264_vaapi\n"
            "  --list             list outputs and workspaces, then exit\n"
            "  --quiet            no progress on stderr\n");
}

static bool parse_crop(const char *s) {
    return sscanf(s, "%d,%d,%d,%d", &opt_crop_x, &opt_crop_y, &opt_crop_w, &opt_crop_h) == 4;
}

static bool parse_logical(const char *s) {
    return sscanf(s, "%dx%d", &opt_logical_w, &opt_logical_h) == 2;
}

int main(int argc, char **argv) {
    wl_list_init(&outputs);
    wl_list_init(&groups);
    wl_list_init(&workspaces);

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        const char *v = (i + 1 < argc) ? argv[i + 1] : NULL;
        if (strcmp(a, "--monitor") == 0 && v) {
            opt_monitor = v;
            i++;
        } else if (strcmp(a, "--output") == 0 && v) {
            opt_output = v;
            i++;
        } else if (strcmp(a, "--fps") == 0 && v) {
            opt_fps = atoi(v);
            i++;
        } else if (strcmp(a, "--frames") == 0 && v) {
            opt_frames = atoi(v);
            i++;
        } else if (strcmp(a, "--crop") == 0 && v) {
            if (!parse_crop(v)) {
                logmsg("lucidcap: bad --crop '%s'", v);
                return 2;
            }
            i++;
        } else if (strcmp(a, "--logical") == 0 && v) {
            if (!parse_logical(v)) {
                logmsg("lucidcap: bad --logical '%s'", v);
                return 2;
            }
            i++;
        } else if (strcmp(a, "--audio") == 0 && v) {
            opt_audio = v;
            i++;
        } else if (strcmp(a, "--encoder") == 0 && v) {
            opt_encoder = v;
            i++;
        } else if (strcmp(a, "--device") == 0 && v) {
            opt_device = v;
            i++;
        } else if (strcmp(a, "--list") == 0) {
            opt_list = true;
        } else if (strcmp(a, "--quiet") == 0) {
            opt_quiet = true;
        } else if (strcmp(a, "--help") == 0 || strcmp(a, "-h") == 0) {
            usage(stdout);
            return 0;
        } else {
            logmsg("lucidcap: unknown argument '%s'", a);
            usage(stderr);
            return 2;
        }
    }

    if (!opt_list && !opt_output) {
        usage(stderr);
        return 2;
    }
    if (opt_fps <= 0)
        opt_fps = 30;
    frame_limit = opt_frames > 0 ? opt_frames : 0;

    display = wl_display_connect(NULL);
    if (!display) {
        logmsg("lucidcap: could not connect to the Wayland display");
        return 1;
    }

    registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(display); /* globals */
    wl_display_roundtrip(display); /* output names + workspace list */

    if (!shm || !ws_manager || !ws_source_manager || !capture_manager) {
        logmsg("lucidcap: the compositor does not offer workspace capture "
               "(need ext-workspace, hyprland-workspace-image-capture-source and ext-image-copy-capture)");
        return 1;
    }

    struct output *o;
    if (opt_monitor && *opt_monitor) {
        wl_list_for_each(o, &outputs, link) {
            if (strcmp(o->name, opt_monitor) == 0) {
                target_output = o;
                break;
            }
        }
        if (!target_output) {
            logmsg("lucidcap: no output named '%s'", opt_monitor);
            return 1;
        }
    } else if (!wl_list_empty(&outputs)) {
        struct output *first;
        target_output = wl_container_of(outputs.next, first, link);
    }

    if (opt_list) {
        logmsg("lucidcap: outputs:");
        wl_list_for_each(o, &outputs, link) { logmsg("  %s", o->name); }
        logmsg("lucidcap: workspaces:");
        struct ws *w;
        wl_list_for_each(w, &workspaces, link) {
            bool inTarget = false;
            if (w->group) {
                for (int i = 0; i < w->group->noutputs; i++) {
                    if (w->group->outputs[i] == (target_output ? target_output->obj : NULL))
                        inTarget = true;
                }
            }
            logmsg("  %-24s active=%d target=%d", w->name, !!(w->state & EXT_WORKSPACE_HANDLE_V1_STATE_ACTIVE), inTarget);
        }
        return 0;
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGPIPE, SIG_IGN);

    /* the workspace events may have landed before the output names did, so
     * pick the starting workspace here rather than relying on manager_done */
    if (phase == PHASE_WAIT_WORKSPACES) {
        struct ws *w = pick_workspace();
        if (!w) {
            logmsg("lucidcap: no active workspace on %s", target_output ? target_output->name : "?");
            return 1;
        }
        start_session(w);
    }

    while (running) {
        while (wl_display_prepare_read(display) != 0) {
            if (wl_display_dispatch_pending(display) < 0) {
                running = 0;
                break;
            }
        }
        if (!running)
            break;

        wl_display_flush(display);

        int timeout = -1;
        if (phase == PHASE_RUNNING && !frame_inflight) {
            const long long interval = 1000 / (opt_fps > 0 ? opt_fps : 30);
            const long long deadline = t_start_ms + frames_written * interval;
            const long long left     = deadline - now_ms();
            timeout                  = left > 0 ? (int)left : 0;
        }

        struct pollfd pfd = {.fd = wl_display_get_fd(display), .events = POLLIN};
        int           r   = poll(&pfd, 1, timeout);
        if (r > 0 && (pfd.revents & POLLIN)) {
            if (wl_display_read_events(display) < 0) {
                running = 0;
                break;
            }
            if (wl_display_dispatch_pending(display) < 0) {
                running = 0;
                break;
            }
        } else {
            wl_display_cancel_read(display);
            if (r < 0 && errno != EINTR) {
                running = 0;
                break;
            }
        }

        if (phase == PHASE_RUNNING && !frame_inflight) {
            const long long interval = 1000 / (opt_fps > 0 ? opt_fps : 30);
            const long long deadline = t_start_ms + frames_written * interval;
            if (now_ms() >= deadline)
                start_frame();
        }
    }

    teardown_session();
    finish();

    if (frames_written > 0 && t_start_ms > 0) {
        const long long ms = now_ms() - t_start_ms;
        logmsg("lucidcap: %lld frames in %.2fs (%.1f fps)", frames_written, ms / 1000.0, frames_written * 1000.0 / (double)(ms > 0 ? ms : 1));
    }

    if (shm_buffer)
        wl_buffer_destroy(shm_buffer);
    if (shm_pool)
        wl_shm_pool_destroy(shm_pool);
    if (shm_data)
        munmap(shm_data, shm_size);

    wl_display_disconnect(display);
    return exit_code;
}
