//go:build !darwin && !linux

package guardian

import "fmt"

func execCodexCLI(Config, string, []string) error {
	return fmt.Errorf("Codex CLI launch is supported on macOS and Linux")
}

func restartGuardianDaemon() error {
	return fmt.Errorf("guardian daemon restart is supported on macOS and Linux")
}
