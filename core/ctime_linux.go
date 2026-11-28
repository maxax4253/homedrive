//go:build linux

package main

import (
	"io/fs"
	"syscall"
)

// changeTime: when the file was last renamed/changed (moving into the trash updates it).
func changeTime(info fs.FileInfo) float64 {
	if st, ok := info.Sys().(*syscall.Stat_t); ok {
		return float64(st.Ctim.Sec) + float64(st.Ctim.Nsec)/1e9
	}
	return fileTime(info)
}
