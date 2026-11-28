//go:build !linux && !darwin

package main

import "io/fs"

func changeTime(info fs.FileInfo) float64 { return fileTime(info) }
