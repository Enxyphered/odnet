#+build windows
package odnetlib

import "core:strings"
import "core:sync"
import "core:thread"
import win "core:sys/windows"

static_watcher_worker :: proc(data: rawptr) {
	mount := cast(^Static_Mount)data
	w_dir := win.utf8_to_wstring(mount.fs_dir)
	defer delete(w_dir)

	handle := win.FindFirstChangeNotificationW(
		cast(^u16)w_dir,
		win.TRUE,
		win.FILE_NOTIFY_CHANGE_LAST_WRITE | win.FILE_NOTIFY_CHANGE_FILE_NAME | win.FILE_NOTIFY_CHANGE_SIZE,
	)
	if handle == win.INVALID_HANDLE_VALUE do return
	defer win.FindCloseChangeNotification(handle)

	for {
		wait_res := win.WaitForSingleObject(handle, 200)
		if wait_res == win.WAIT_OBJECT_0 {
			sync.rw_mutex_lock(&global_static_cache.rw_lock)
			global_static_cache.version += 1
			norm_mount := normalize_static_path(mount.fs_dir)
			for i in 0 ..< global_static_cache.num_files {
				f := &global_static_cache.files[i]
				if strings.has_prefix(f.path, norm_mount) {
					f.valid = false
				}
			}
			sync.rw_mutex_unlock(&global_static_cache.rw_lock)
			win.FindNextChangeNotification(handle)
		}
	}
}

start_static_mount_watcher :: proc(mount: ^Static_Mount) {
	thread.create_and_start_with_data(mount, static_watcher_worker)
}
