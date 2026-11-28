//go:build !windows

package main

import "syscall"

// diskSpace returns the total, used and free (available to us) bytes of the disk
// holding path, counted the same way as `df` and the old server.
func diskSpace(path string) (total, used, free int64) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return 0, 0, 0
	}
	bs := int64(st.Bsize)
	return int64(st.Blocks) * bs, (int64(st.Blocks) - int64(st.Bfree)) * bs, int64(st.Bavail) * bs
}
