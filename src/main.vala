/* Copyright 2009-2010 Yorba Foundation
 *
 * This software is licensed under the GNU LGPL (version 2.1 or later).
 * See the COPYING file in this distribution. 
 */

#if !NO_LIBUNIQUE

enum ShotwellCommand {
    // user-defined commands must be positive ints
    MOUNTED_CAMERA = 1
}

Unique.Response on_shotwell_message(Unique.App shotwell, int command, Unique.MessageData data, 
    uint timestamp) {
    Unique.Response response = Unique.Response.OK;
    
    switch (command) {
        case ShotwellCommand.MOUNTED_CAMERA:
            LibraryWindow.get_app().mounted_camera_shell_notification(data.get_text(), false);
        break;
        
        case Unique.Command.ACTIVATE:
            LibraryWindow.get_app().present_with_time(timestamp);
        break;
        
        default:
            // should be Unique.Response.PASSTHROUGH, but value isn't bound in vapi
            response = (Unique.Response) 4;
        break;
    }
    
    return response;
}
#endif

private Timer startup_timer = null;

void library_exec(string[] mounts) {
#if NO_LIBUNIQUE
    if (already_running())
        return;
#else
    // the library is single-instance; editing windows are one-process-per
    Unique.App shotwell = new Unique.App("org.yorba.shotwell", null);
    shotwell.add_command("MOUNTED_CAMERA", (int) ShotwellCommand.MOUNTED_CAMERA);
    shotwell.message_received.connect(on_shotwell_message);

    if (shotwell.is_running) {
        // send attached cameras & activate the window
        foreach (string mount in mounts) {
            Unique.MessageData data = new Unique.MessageData();
            data.set_text(mount, -1);
            
            shotwell.send_message((int) ShotwellCommand.MOUNTED_CAMERA, data);
        }
        
        shotwell.send_message((int) Unique.Command.ACTIVATE, null);
        
        // notified running app; this one exits
        return;
    }
#endif

    // initialize DatabaseTable before verification
    DatabaseTable.init(AppDirs.get_data_subdir("data").get_child("photo.db"));

    // validate the databases prior to using them
    message("Verifying database ...");
    string errormsg = null;
    string app_version;
    int schema_version;
    DatabaseVerifyResult result = verify_database(out app_version, out schema_version);
    switch (result) {
        case DatabaseVerifyResult.OK:
            // do nothing; no problems
        break;
        
        case DatabaseVerifyResult.FUTURE_VERSION:
            errormsg = _("Your photo library is not compatible with this version of Shotwell.  It appears it was created by Shotwell %s (schema %d).  This version is %s (schema %d).  Please use the latest version of Shotwell.").printf(
                app_version, schema_version, Resources.APP_VERSION, DatabaseTable.SCHEMA_VERSION);
        break;
        
        case DatabaseVerifyResult.UPGRADE_ERROR:
            errormsg = _("Shotwell was unable to upgrade your photo library from version %s (schema %d) to %s (schema %d).  For more information please check the Shotwell Wiki at %s").printf(
                app_version, schema_version, Resources.APP_VERSION, DatabaseTable.SCHEMA_VERSION,
                Resources.get_users_guide_url());
        break;
        
        case DatabaseVerifyResult.NO_UPGRADE_AVAILABLE:
            errormsg = _("Your photo library is not compatible with this version of Shotwell.  It appears it was created by Shotwell %s (schema %d).  This version is %s (schema %d).  Please clear your library by deleting %s and re-import your photos.").printf(
                app_version, schema_version, Resources.APP_VERSION, DatabaseTable.SCHEMA_VERSION,
                AppDirs.get_data_dir().get_path());
        break;
        
        default:
            errormsg = _("Unknown error attempting to verify Shotwell's database: %s").printf(
                result.to_string());
        break;
    }
    
    if (errormsg != null) {
        Gtk.MessageDialog dialog = new Gtk.MessageDialog(null, Gtk.DialogFlags.MODAL, 
            Gtk.MessageType.ERROR, Gtk.ButtonsType.OK, "%s", errormsg);
        dialog.title = Resources.APP_TITLE;
        dialog.run();
        dialog.destroy();
        
        DatabaseTable.terminate();
        
        return;
    }

    // initialize GStreamer, but don't pass it our actual command line arguments -- we don't
    // want our end users to be able to parameterize the GStreamer configuration
    string[] fake_args = new string[0];
    Gst.init(ref fake_args);

    Video.init();

    ProgressDialog progress_dialog = null;
    AggregateProgressMonitor aggregate_monitor = null;
    ProgressMonitor monitor = null;

    if (!no_startup_progress) {
        // only throw up a startup progress dialog if over a reasonable amount of objects ... multiplying
        // photos by two because there's two heavy-duty operations on them: creating the LibraryPhoto
        // objects and then populating the initial page with them.
        uint64 grand_total = (PhotoTable.get_instance().get_row_count() * 2) 
            + EventTable.get_instance().get_row_count();
        if (grand_total > 20000) {
            progress_dialog = new ProgressDialog(null, _("Loading Shotwell"));
            progress_dialog.update_display_every(300);
            spin_event_loop();
            
            aggregate_monitor = new AggregateProgressMonitor(grand_total, progress_dialog.monitor);
            monitor = aggregate_monitor.monitor;
        }
    }
    
    ThumbnailCache.init();
    if (aggregate_monitor != null)
        aggregate_monitor.next_step("LibraryPhoto.init");
    LibraryPhoto.init(monitor);
    if (aggregate_monitor != null)
        aggregate_monitor.next_step("Event.init");
    MediaCollectionRegistry.get_instance().register_collection(Photo.TYPENAME, LibraryPhoto.global);
    MediaCollectionRegistry.get_instance().register_collection(Video.TYPENAME, Video.global);
    Event.init(monitor);
    Tag.init();
    AlienDatabaseHandler.init();
    Tombstone.init();
    MetadataWriter.init();
    
    // create main library application window
    if (aggregate_monitor != null)
        aggregate_monitor.next_step("LibraryWindow");
    LibraryWindow library_window = new LibraryWindow(monitor);
    
    if (aggregate_monitor != null)
        aggregate_monitor.next_step("done");
    
    // destroy and tear down everything ... no need for them to stick around the lifetime of the
    // application
    
    monitor = null;
    aggregate_monitor = null;
    if (progress_dialog != null)
        progress_dialog.destroy();
    progress_dialog = null;

#if !NO_CAMERA
    // report mount points
    foreach (string mount in mounts)
        library_window.mounted_camera_shell_notification(mount, true);
#endif

    library_window.show_all();

    if (Config.get_instance().get_show_welcome_dialog() &&
        LibraryPhoto.global.get_count() == 0) {
        WelcomeDialog welcome = new WelcomeDialog(library_window);
        Config.get_instance().set_show_welcome_dialog(welcome.execute(out do_fspot_import,
            out do_system_pictures_import));
    } else {
        Config.get_instance().set_show_welcome_dialog(false);
    }
    
    if (do_fspot_import) {
        FSpotDatabaseDriver.do_import(report_fspot_import);
    } else if (do_system_pictures_import) { /* else-if because f-spot import will run the system
                                               pictures import automatically if it's requested */
        run_system_pictures_import();
    }

    debug("%lf seconds to Gtk.main()", startup_timer.elapsed());
    
    Application.get_instance().start();
    
    MetadataWriter.terminate();
    Tombstone.terminate();
    AlienDatabaseHandler.terminate();
    Tag.terminate();
    Event.terminate();
    LibraryPhoto.terminate();
    ThumbnailCache.terminate();
    Video.terminate();

    DatabaseTable.terminate();
}

private bool do_system_pictures_import = false;
private bool do_fspot_import = false;

public void run_system_pictures_import(ImportManifest? fspot_exclusion_manifest = null) {
    if (!do_system_pictures_import)
        return;

    Gee.ArrayList<FileImportJob> jobs = new Gee.ArrayList<FileImportJob>();
    jobs.add(new FileImportJob(AppDirs.get_import_dir(), false));
    
    LibraryWindow library_window = (LibraryWindow) AppWindow.get_instance();
    
    BatchImport batch_import = new BatchImport(jobs, "startup_import",
        report_system_pictures_import, null, null, null, null, fspot_exclusion_manifest);
    library_window.enqueue_batch_import(batch_import, true);

    library_window.switch_to_import_queue_page();
}

private void report_fspot_import(ImportManifest manifest, BatchImportRoll import_roll) {
    ImportUI.report_manifest(manifest, true);
    
    if (do_system_pictures_import)
       run_system_pictures_import(manifest);
}

private void report_system_pictures_import(ImportManifest manifest, BatchImportRoll import_roll) {
    /* Don't report the manifest to the user if F-Spot import was done and the entire manifest
       is empty. An empty manifest in this case results from files that were already imported
       in the F-Spot import phase being skipped. Note that we are testing against manifest.all,
       not manifest.success; manifest.all is zero when no files were enqueued for import in the
       first place and the only way this happens is if all files were skipped -- even failed
       files are counted in manifest.all */
    if (do_fspot_import && (manifest.all.size == 0))
        return;

    ImportUI.report_manifest(manifest, true);
}

void editing_exec(string filename) {
    // init modules direct-editing relies on
    DatabaseTable.init(null);
    DirectPhoto.init();

    // TODO: At some point in the future, to support mixed-media in direct-edit mode, we will
    //       refactor DirectPhotoSourceCollection to be a MediaSourceCollection. At that point,
    //       we'll need to register DirectPhoto.global with the MediaCollectionRegistry
    
    DirectWindow direct_window = new DirectWindow(File.new_for_commandline_arg(filename));
    direct_window.show_all();
    
    debug("%lf seconds to Gtk.main()", startup_timer.elapsed());
    
    Application.get_instance().start();
    
    DirectPhoto.terminate();
    DatabaseTable.terminate();
}

bool no_startup_progress = false;
bool no_mimicked_images = false;
string data_dir = null;
bool startup_auto_import = false;
bool autocommit_metadata = false;
bool show_version = false;
bool runtime_monitoring = false;
bool runtime_import = false;

const OptionEntry[] options = {
    { "autocommit-metadata", 0, 0, OptionArg.NONE, &autocommit_metadata,
        N_("Auto-commit metadata to master files (experimental)"), null },
    { "auto-import", 0, 0, OptionArg.NONE, &startup_auto_import,
        N_("Auto-import files discovered in library directory at startup (experimental)"), null },
    { "datadir", 'd', 0, OptionArg.FILENAME, &data_dir,
        N_("Path to Shotwell's private data"), N_("DIRECTORY") },
    { "no-mimicked-images", 0, 0, OptionArg.NONE, &no_mimicked_images,
        N_("Don't used JPEGs to display RAW images"), null },
    { "no-startup-progress", 0, 0, OptionArg.NONE, &no_startup_progress,
        N_("Don't display startup progress meter"), null },
    { "runtime-import", 0, 0, OptionArg.NONE, &runtime_import,
        N_("Import new files in library directory detected at runtime (experimental)"), null },
    { "runtime-monitoring", 0, 0, OptionArg.NONE, &runtime_monitoring,
        N_("Monitor library directory at runtime for changes (experimental)"), null },
    { "version", 'V', 0, OptionArg.NONE, &show_version,
        N_("Show the application's version"), null },
    { null }
};

void main(string[] args) {
    // Call AppDirs init *before* calling Gtk.init_with_args, as it will strip the
    // exec file from the array
    AppDirs.init(args[0]);
#if WINDOWS
    win_init(AppDirs.get_exec_dir());
#endif

    // init GTK (valac has already called g_threads_init())
    try {
        Gtk.init_with_args(ref args, _("[FILE]"), (OptionEntry []) options, Resources.APP_GETTEXT_PACKAGE);
    } catch (Error e) {
        print(e.message + "\n");
        print(_("Run '%s --help' to see a full list of available command line options.\n"), args[0]);
        AppDirs.terminate();
        return;
    }
    
    if (show_version) {
        print("%s %s\n", Resources.APP_TITLE, Resources.APP_VERSION);
        
        AppDirs.terminate();
        
        return;
    }
    
    // init debug prior to anything else (except Gtk, which it relies on, and AppDirs, which needs
    // to be set ASAP) ... since we need to know what mode we're in, examine the command-line
    // first
    
    // walk command-line arguments for camera mounts or filename for direct editing ... only one
    // filename supported for now, so take the first one and drop the rest ... note that URIs for
    // filenames are currently not permitted, to differentiate between mount points
    string[] mounts = new string[0];
    string filename = null;

    for (int ctr = 1; ctr < args.length; ctr++) {
        string arg = args[ctr];
        
        if (LibraryWindow.is_mount_uri_supported(arg)) {
            mounts += arg;
        } else if (is_string_empty(filename) && !arg.contains("://")) {
            filename = arg;
        }
    }
    
    Debug.init(is_string_empty(filename) ? Debug.LIBRARY_PREFIX : Debug.VIEWER_PREFIX);
    Application.init();
    
    // set custom data directory if it's been supplied
    if (data_dir != null) {
        if (!Path.is_absolute(data_dir))
            data_dir = Path.build_filename(Environment.get_current_dir(), data_dir);

        AppDirs.set_data_dir(File.parse_name(data_dir));
    }
    
    // Verify the private data directory before continuing
    AppDirs.verify_data_dir();
    
    // init internationalization with the default system locale
    InternationalSupport.init(Resources.APP_GETTEXT_PACKAGE, args);
    
    startup_timer = new Timer();
    startup_timer.start();
    
    // set up GLib environment
    GLib.Environment.set_application_name(Resources.APP_TITLE);
    
    // in both the case of running as the library or an editor, Resources is always
    // initialized
    Resources.init();
    
    // since it's possible for a mount name to be passed that's not supported (and hence an empty
    // mount list), or for nothing to be on the command-line at all, only go to direct editing if a
    // filename is spec'd
    if (is_string_empty(filename))
        library_exec(mounts);
    else
        editing_exec(filename);
    
    // terminate mode-inspecific modules
    Resources.terminate();
    Application.terminate();
    Debug.terminate();
    AppDirs.terminate();
}

