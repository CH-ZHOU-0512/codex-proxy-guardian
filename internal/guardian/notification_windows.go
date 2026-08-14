//go:build windows

package guardian

import "errors"

func notifyAutomaticUpdate(_, _ string) error {
	return errors.New("the native desktop notification path is not used on Windows")
}
