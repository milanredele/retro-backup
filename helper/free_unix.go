//go:build linux || darwin || freebsd || netbsd || openbsd

package main

import "syscall"

// freeBytes returns the bytes available to an unprivileged user on the
// filesystem holding dir.
func freeBytes(dir string) (uint64, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(dir, &st); err != nil {
		return 0, err
	}
	return uint64(st.Bavail) * uint64(st.Bsize), nil
}
