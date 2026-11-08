#+build linux
package odnetlib

start_static_mount_watcher :: proc(mount: ^Static_Mount) {
	// Linux inotify watcher or fallback
}
