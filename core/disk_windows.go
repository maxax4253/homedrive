//go:build windows

package main

import (
	"syscall"
	"unsafe"
)

var getDiskFreeSpaceEx = syscall.NewLazyDLL("kernel32.dll").NewProc("GetDiskFreeSpaceExW")

func diskSpace(path string) (total, used, free int64) {
	p, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return 0, 0, 0
	}
	var avail, tot, totalFree uint64
	r, _, _ := getDiskFreeSpaceEx.Call(uintptr(unsafe.Pointer(p)), uintptr(unsafe.Pointer(&avail)),
		uintptr(unsafe.Pointer(&tot)), uintptr(unsafe.Pointer(&totalFree)))
	if r == 0 {
		return 0, 0, 0
	}
	return int64(tot), int64(tot - totalFree), int64(avail)
}
