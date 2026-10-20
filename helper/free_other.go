//go:build !linux && !darwin && !freebsd && !netbsd && !openbsd && !windows

package main

import "errors"

func freeBytes(dir string) (uint64, error) {
	return 0, errors.New("free space not supported on this OS")
}
