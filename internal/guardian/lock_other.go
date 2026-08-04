//go:build !darwin && !linux

package guardian

import (
	"os"
	"path/filepath"
)

func acquireInstanceLock() (*os.File, error) {
	root, err := dataRoot()
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(root, 0o700); err != nil {
		return nil, err
	}
	return os.OpenFile(filepath.Join(root, "guardian.lock"), os.O_CREATE|os.O_RDWR, 0o600)
}
