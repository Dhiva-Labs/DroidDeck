#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* file_chooser_channel;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// ---- droiddeck/file_chooser ------------------------------------------------
// lib/services/portal_file_picker.dart asks the XDG desktop portal first and
// lands here only when no portal answers (XFCE and other desktops often ship
// without a FileChooser backend), so these are plain in-process GTK dialogs.
// parentWindow hands the portal our X11 window so its dialog stacks above us.

static const gchar* arg_string(FlValue* args, const char* key,
                               const gchar* fallback) {
  FlValue* value = fl_value_get_type(args) == FL_VALUE_TYPE_MAP
                       ? fl_value_lookup_string(args, key)
                       : nullptr;
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING
             ? fl_value_get_string(value)
             : fallback;
}

static gboolean arg_bool(FlValue* args, const char* key) {
  FlValue* value = fl_value_get_type(args) == FL_VALUE_TYPE_MAP
                       ? fl_value_lookup_string(args, key)
                       : nullptr;
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL &&
         fl_value_get_bool(value);
}

static void file_chooser_response_cb(GtkDialog* dialog, gint response_id,
                                     gpointer user_data) {
  g_autoptr(FlMethodCall) method_call = FL_METHOD_CALL(user_data);
  GtkFileChooser* chooser = GTK_FILE_CHOOSER(dialog);
  const gboolean accepted = response_id == GTK_RESPONSE_ACCEPT;

  // saveFile answers a path or null; openFiles a (possibly empty) list.
  g_autoptr(FlValue) result = nullptr;
  if (gtk_file_chooser_get_action(chooser) == GTK_FILE_CHOOSER_ACTION_SAVE) {
    g_autofree gchar* path =
        accepted ? gtk_file_chooser_get_filename(chooser) : nullptr;
    result = path != nullptr ? fl_value_new_string(path) : fl_value_new_null();
  } else {
    result = fl_value_new_list();
    GSList* paths = accepted ? gtk_file_chooser_get_filenames(chooser) : nullptr;
    for (GSList* p = paths; p != nullptr; p = p->next) {
      fl_value_append_take(result,
                           fl_value_new_string(static_cast<gchar*>(p->data)));
    }
    g_slist_free_full(paths, g_free);
  }
  gtk_widget_destroy(GTK_WIDGET(dialog));

  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  fl_method_call_respond(method_call, response, nullptr);
}

static void show_file_chooser(GtkWindow* parent, FlMethodCall* method_call,
                              gboolean save) {
  FlValue* args = fl_method_call_get_args(method_call);
  const GtkFileChooserAction action =
      save ? GTK_FILE_CHOOSER_ACTION_SAVE
      : arg_bool(args, "directory") ? GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER
                                    : GTK_FILE_CHOOSER_ACTION_OPEN;
  GtkWidget* dialog = gtk_file_chooser_dialog_new(
      arg_string(args, "title", save ? "Save file" : "Open file"), parent,
      action, "_Cancel", GTK_RESPONSE_CANCEL, save ? "_Save" : "_Open",
      GTK_RESPONSE_ACCEPT, nullptr);
  GtkFileChooser* chooser = GTK_FILE_CHOOSER(dialog);
  gtk_window_set_modal(GTK_WINDOW(dialog), TRUE);
  gtk_dialog_set_default_response(GTK_DIALOG(dialog), GTK_RESPONSE_ACCEPT);
  gtk_file_chooser_set_current_folder(chooser, g_get_home_dir());

  if (save) {
    gtk_file_chooser_set_do_overwrite_confirmation(chooser, TRUE);
    const gchar* name = arg_string(args, "suggestedName", nullptr);
    if (name != nullptr) {
      gtk_file_chooser_set_current_name(chooser, name);
    }
  } else {
    gtk_file_chooser_set_select_multiple(chooser, arg_bool(args, "multiple"));
  }

  FlValue* patterns = fl_value_get_type(args) == FL_VALUE_TYPE_MAP
                          ? fl_value_lookup_string(args, "filterPatterns")
                          : nullptr;
  if (patterns != nullptr && fl_value_get_type(patterns) == FL_VALUE_TYPE_LIST) {
    GtkFileFilter* filter = gtk_file_filter_new();
    gtk_file_filter_set_name(filter, arg_string(args, "filterName", ""));
    for (size_t i = 0; i < fl_value_get_length(patterns); i++) {
      FlValue* glob = fl_value_get_list_value(patterns, i);
      if (fl_value_get_type(glob) == FL_VALUE_TYPE_STRING) {
        gtk_file_filter_add_pattern(filter, fl_value_get_string(glob));
      }
    }
    gtk_file_chooser_add_filter(chooser, filter);
  }

  g_signal_connect(dialog, "response", G_CALLBACK(file_chooser_response_cb),
                   g_object_ref(method_call));
  gtk_widget_show(dialog);
}

static void file_chooser_method_cb(FlMethodChannel* channel,
                                   FlMethodCall* method_call,
                                   gpointer user_data) {
  GtkWindow* window = GTK_WINDOW(user_data);
  const gchar* method = fl_method_call_get_name(method_call);

  if (g_strcmp0(method, "openFiles") == 0 ||
      g_strcmp0(method, "saveFile") == 0) {
    show_file_chooser(window, method_call,
                      g_strcmp0(method, "saveFile") == 0);
    return;
  }

  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(method, "parentWindow") == 0) {
    g_autofree gchar* handle = nullptr;
#ifdef GDK_WINDOWING_X11
    GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window));
    if (gdk_window != nullptr && GDK_IS_X11_WINDOW(gdk_window)) {
      handle = g_strdup_printf("x11:%lx", gdk_x11_window_get_xid(gdk_window));
    }
#endif
    g_autoptr(FlValue) result = fl_value_new_string(handle ? handle : "");
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(method_call, response, nullptr);
}

// Sets the window icon from the system hicolor theme if DroidDeck is
// installed (packaging/build_deb.sh puts it at the path below), otherwise
// falls back to the copy shipped inside this bundle's Flutter assets so the
// icon still shows up when running straight out of build/linux/.../bundle.
static void set_window_icon(GtkWindow* window) {
  const char* installed = "/usr/share/icons/hicolor/256x256/apps/droiddeck.png";
  g_autoptr(GError) error = nullptr;

  if (g_file_test(installed, G_FILE_TEST_EXISTS)) {
    if (!gtk_window_set_icon_from_file(window, installed, &error)) {
      g_warning("Failed to load window icon '%s': %s", installed,
                error->message);
    }
    return;
  }

  // Resolve a path relative to the running executable (not the process's
  // current working directory, which the desktop launcher doesn't promise)
  // so this also works for the /usr/bin/droiddeck wrapper that execs the
  // real binary out of /usr/lib/droiddeck.
  g_autofree gchar* exe_path = g_file_read_link("/proc/self/exe", nullptr);
  if (exe_path == nullptr) {
    return;
  }
  g_autofree gchar* exe_dir = g_path_get_dirname(exe_path);
  g_autofree gchar* bundled = g_build_filename(
      exe_dir, "data", "flutter_assets", "assets", "icon",
      "droiddeck_256.png", nullptr);
  if (g_file_test(bundled, G_FILE_TEST_EXISTS)) {
    if (!gtk_window_set_icon_from_file(window, bundled, &error)) {
      g_warning("Failed to load window icon '%s': %s", bundled,
                error->message);
    }
  }
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "DroidDeck");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "DroidDeck");
  }

  gtk_window_set_default_size(window, 1280, 720);
  set_window_icon(window);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->file_chooser_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "droiddeck/file_chooser", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->file_chooser_channel, file_chooser_method_cb, window, nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->file_chooser_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
