/*
 * liblucidgtk.so — live-reload the Lucid GTK stylesheet in GTK4 apps.
 *
 * GTK4 loads $XDG_CONFIG_HOME/gtk-4.0/gtk.css exactly once (gtksettings.c,
 * settings_init_style) and never watches it. This tiny shim adds a second
 * provider at USER+1 and reloads it with a GFileMonitor when Lucid rewrites
 * the file. It only does anything in GTK4 processes.
 *
 * Build (support/lucid/build-gtk-shim.sh):
 *   cc -shared -fPIC -O2 -o liblucidgtk.so lucid-gtk-css.c \
 *      $(pkg-config --cflags --libs gtk4) -ldl
 *
 * Use: LD_PRELOAD=/path/liblucidgtk.so nautilus ...
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <gio/gio.h>
#include <gtk/gtk.h>
#include <string.h>

static GtkCssProvider *lucid_provider;
static GFileMonitor *lucid_monitor;
static char *lucid_css_path;
static int lucid_tries;

static void lucid_reload(GtkCssProvider *provider, const char *path, const char *reason)
{
    (void)reason;
    gtk_css_provider_load_from_path(provider, path);
}

static void lucid_file_changed(GFileMonitor *monitor, GFile *file, GFile *other,
                               GFileMonitorEvent event, gpointer data)
{
    (void)monitor;
    (void)other;
    (void)data;
    if (event != G_FILE_MONITOR_EVENT_CHANGED &&
        event != G_FILE_MONITOR_EVENT_CHANGES_DONE_HINT &&
        event != G_FILE_MONITOR_EVENT_CREATED &&
        event != G_FILE_MONITOR_EVENT_MOVED_IN &&
        event != G_FILE_MONITOR_EVENT_MOVED)
        return;

    char *name = g_file_get_basename(file);
    if (name && strcmp(name, "gtk.css") == 0 && lucid_provider && lucid_css_path)
        lucid_reload(lucid_provider, lucid_css_path, "file change");
    g_free(name);
}

static gboolean lucid_install(gpointer data)
{
    (void)data;

    if (lucid_provider)
        return G_SOURCE_REMOVE;

    if (!gtk_is_initialized() || !gdk_display_get_default()) {
        if (++lucid_tries > 60)
            return G_SOURCE_REMOVE;
        return G_SOURCE_CONTINUE;
    }

    lucid_css_path = g_build_filename(g_get_user_config_dir(), "gtk-4.0", "gtk.css", NULL);
    if (!g_file_test(lucid_css_path, G_FILE_TEST_IS_REGULAR))
        return G_SOURCE_REMOVE;

    lucid_provider = gtk_css_provider_new();
    lucid_reload(lucid_provider, lucid_css_path, "initial");
    gtk_style_context_add_provider_for_display(
        gdk_display_get_default(),
        GTK_STYLE_PROVIDER(lucid_provider),
        GTK_STYLE_PROVIDER_PRIORITY_USER + 1);

    char *dir = g_path_get_dirname(lucid_css_path);
    GFile *dir_file = g_file_new_for_path(dir);
    lucid_monitor = g_file_monitor_directory(dir_file, G_FILE_MONITOR_NONE, NULL, NULL);
    if (lucid_monitor)
        g_signal_connect(lucid_monitor, "changed", G_CALLBACK(lucid_file_changed), NULL);
    g_object_unref(dir_file);
    g_free(dir);

    return G_SOURCE_REMOVE;
}

static void lucid_schedule(void)
{
    if (!lucid_provider)
        g_timeout_add(100, lucid_install, NULL);
}

/* Apps that initialize GTK directly. */
typedef void (*gtk_init_fn)(void);
typedef gboolean (*gtk_init_check_fn)(void);

void gtk_init(void)
{
    static gtk_init_fn real;
    if (!real)
        real = (gtk_init_fn)dlsym(RTLD_NEXT, "gtk_init");
    if (real)
        real();
    lucid_schedule();
}

gboolean gtk_init_check(void)
{
    static gtk_init_check_fn real;
    if (!real)
        real = (gtk_init_check_fn)dlsym(RTLD_NEXT, "gtk_init_check");
    gboolean ok = real ? real() : FALSE;
    if (ok)
        lucid_schedule();
    return ok;
}

/* Apps that enter through GApplication (Nautilus, libadwaita apps). */
typedef int (*g_application_run_fn)(GApplication *, int, char **);

int g_application_run(GApplication *app, int argc, char **argv)
{
    static g_application_run_fn real;
    if (!real)
        real = (g_application_run_fn)dlsym(RTLD_NEXT, "g_application_run");
    gboolean is_gtk = G_IS_OBJECT(app) && g_type_is_a(G_OBJECT_TYPE(app), gtk_application_get_type());
    if (is_gtk)
        lucid_schedule();
    return real ? real(app, argc, argv) : 1;
}
