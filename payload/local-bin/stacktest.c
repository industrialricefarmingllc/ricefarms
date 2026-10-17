#include <gtk/gtk.h>

static const char *ui =
  "<interface>"
  "  <object class='GtkStack' id='stack'>"
  "    <child>"
  "      <object class='GtkDropTarget' id='drop_target'>"
  "        <property name='actions'>copy</property>"
  "      </object>"
  "    </child>"
  "    <child>"
  "      <object class='GtkLabel' id='label'>"
  "        <property name='label'>hi</property>"
  "      </object>"
  "    </child>"
  "  </object>"
  "</interface>";

int main (int argc, char **argv) {
  /* use the live display (no toplevel created, so no window pops up) */
  if (!gtk_init_check ()) {
    g_print ("INIT FAILED\n");
    return 2;
  }
  GtkBuilder *b = gtk_builder_new_from_string (ui, -1);
  if (!b) { g_print ("BUILDER FAILED\n"); return 1; }
  GObject *stack = gtk_builder_get_object (b, "stack");
  GObject *dt = gtk_builder_get_object (b, "drop_target");
  g_print ("stack=%p drop_target=%p\n", stack, dt);
  if (dt) {
    GtkWidget *w = gtk_event_controller_get_widget (GTK_EVENT_CONTROLLER (dt));
    g_print ("controller attached to widget: %p (%s)\n",
             w, w ? G_OBJECT_TYPE_NAME (w) : "NULL => DEAD TARGET");
  }
  if (stack) {
    GtkSelectionModel *pages = gtk_stack_get_pages (GTK_STACK (stack));
    g_print ("stack pages: %u\n", g_list_model_get_n_items (G_LIST_MODEL (pages)));
    for (guint i = 0; i < g_list_model_get_n_items (G_LIST_MODEL (pages)); i++) {
      GtkStackPage *p = GTK_STACK_PAGE (g_list_model_get_item (G_LIST_MODEL (pages), i));
      GtkWidget *c = gtk_stack_page_get_child (p);
      g_print ("  page %u child: %s\n", i, c ? G_OBJECT_TYPE_NAME (c) : "NULL");
      g_object_unref (p);
    }
  }
  return 0;
}
