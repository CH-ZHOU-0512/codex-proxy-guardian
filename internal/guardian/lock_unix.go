//go:build darwin || linux

package guardian

import (
	"os"
	"path/filepath"
	"syscall"
)

func acquireInstanceLock() (*os.File, error) {
	root, err := dataRoot()
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(root, 0o700); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(filepath.Join(root, "guardian.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		file.Close()
		return nil, err
	}
	return file, nil
}
