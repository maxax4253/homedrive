//go:build darwin

package main

import (
	"io/fs"
	"syscall"
)

func changeTime(info fs.FileInfo) float64 {
	if st, ok := info.Sys().(*syscall.Stat_t); ok {
		return float64(st.Ctimespec.Sec) + float64(st.Ctimespec.Nsec)/1e9
	}
	return fileTime(info)
}
