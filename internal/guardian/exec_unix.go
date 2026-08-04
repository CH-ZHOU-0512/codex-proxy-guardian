//go:build darwin || linux

package guardian

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
)

func execCodexCLI(cfg Config, proxyURI string, arguments []string) error {
	commandPath, err := exec.LookPath(cfg.CodexCommand)
	if err != nil {
		return fmt.Errorf("Codex CLI %q was not found on PATH: %w", cfg.CodexCommand, err)
	}
	argv := append([]string{commandPath}, arguments...)
	return syscall.Exec(commandPath, argv, proxyEnvironment(proxyURI, cfg.NoProxy))
}

func restartGuardianDaemon() error {
	binary, err := os.Executable()
	if err != nil {
		return err
	}
	if resolved, resolveErr := filepath.EvalSymlinks(binary); resolveErr == nil {
		binary = resolved
	}
	return syscall.Exec(binary, []string{binary, "daemon"}, os.Environ())
}
