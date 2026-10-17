#include <gtk/gtk.h>

/* Mirrors Loupe 50.0's drop gate exactly:
 *   different_source = drop.drag == NULL (ours has no own drag source,
 *     same as Loupe when idle)
 *   correct_format = formats contain GdkFileList
 * verdict = different_source && correct_format
 * Target actions = COPY only, like Loupe's .ui.
 */
static gboolean
on_accept (GtkDropTarget *target, GdkDrop *drop, gpointer data) {
  GdkContentFormats *formats = gdk_drop_get_formats (drop);
  char *f = gdk_content_formats_to_string (formats);
  GdkDrag *drag = gdk_drop_get_drag (drop);

  gsize n = 0;
  const GType *types = gdk_content_formats_get_gtypes (formats, &n);
  gboolean has_file_list = FALSE;
  for (gsize i = 0; i < n; i++) {
    if (types[i] == GDK_TYPE_FILE_LIST)
      has_file_list = TRUE;
  }

  gboolean different_source = (drag == NULL);
  gboolean verdict = different_source && has_file_list;
  g_print ("LOUPE-SIM accept: actions=%u drag=%s hasFileList=%d different_source=%d verdict=%d formats=[%s]\n",
           (guint) gdk_drop_get_actions (drop),
           drag ? "SOME" : "NULL",
           has_file_list, different_source, verdict, f);
  g_free (f);
  return verdict;
}

static gboolean
on_drop (GtkDropTarget *target, const GValue *value, double x, double y, gpointer data) {
  g_print ("LOUPE-SIM drop: type=%s\n", G_VALUE_TYPE_NAME (value));
  return TRUE;
}

static void
activate (GtkApplication *app, gpointer data) {
  GtkWidget *win = gtk_application_window_new (app);
  gtk_window_set_title (GTK_WINDOW (win), "DnD Probe (Loupe sim)");
  gtk_window_set_default_size (GTK_WINDOW (win), 400, 300);
  GtkWidget *label = gtk_label_new ("Drag a Nautilus file over this window.\nWatch the terminal output.");
  gtk_window_set_child (GTK_WINDOW (win), label);
  GtkDropTarget *t = gtk_drop_target_new (GDK_TYPE_FILE_LIST, GDK_ACTION_COPY);
  g_signal_connect (t, "accept", G_CALLBACK (on_accept), NULL);
  g_signal_connect (t, "drop", G_CALLBACK (on_drop), NULL);
  gtk_widget_add_controller (win, GTK_EVENT_CONTROLLER (t));
  gtk_window_present (GTK_WINDOW (win));
}

int main (int argc, char **argv) {
  GtkApplication *app = gtk_application_new ("org.example.dndprobe", G_APPLICATION_DEFAULT_FLAGS);
  g_signal_connect (app, "activate", G_CALLBACK (activate), NULL);
  int s = g_application_run (G_APPLICATION (app), argc, argv);
  g_object_unref (app);
  return s;
}
