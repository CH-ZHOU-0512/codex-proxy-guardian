//go:build linux

package guardian

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func platformInstallUserService(binary string) error {
	userHome, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	configBase := os.Getenv("XDG_CONFIG_HOME")
	if configBase == "" {
		configBase = filepath.Join(userHome, ".config")
	}
	unitPath := filepath.Join(configBase, "systemd", "user", "codex-proxy-guardian.service")
	if _, err := exec.LookPath("systemctl"); err == nil {
		if err := os.MkdirAll(filepath.Dir(unitPath), 0o700); err != nil {
			return err
		}
		systemdPath := strings.ReplaceAll(binary, "%", "%%")
		unit := "[Unit]\nDescription=Codex Proxy Guardian\nAfter=network-online.target\n\n[Service]\nType=simple\nExecStart=" + strconv.Quote(systemdPath) + " daemon\nRestart=always\nRestartSec=5\n\n[Install]\nWantedBy=default.target\n"
		if err := os.WriteFile(unitPath, []byte(unit), 0o600); err != nil {
			return err
		}
		if output, err := exec.Command("systemctl", "--user", "daemon-reload").CombinedOutput(); err == nil {
			if output, err = exec.Command("systemctl", "--user", "enable", "--now", "codex-proxy-guardian.service").CombinedOutput(); err == nil {
				return nil
			}
			_ = output
		}
	}

	autostartPath := filepath.Join(configBase, "autostart", "codex-proxy-guardian.desktop")
	if err := os.MkdirAll(filepath.Dir(autostartPath), 0o700); err != nil {
		return err
	}
	desktop := "[Desktop Entry]\nType=Application\nName=Codex Proxy Guardian\nExec=" + quoteDesktopArgument(binary) + " daemon\nTerminal=false\nX-GNOME-Autostart-enabled=true\nNoDisplay=true\n"
	if err := os.WriteFile(autostartPath, []byte(desktop), 0o600); err != nil {
		return err
	}
	command := exec.Command(binary, "daemon")
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	command.Stdin, command.Stdout, command.Stderr = nil, nil, nil
	return command.Start()
}

func platformUninstallUserService() error {
	userHome, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	configBase := os.Getenv("XDG_CONFIG_HOME")
	if configBase == "" {
		configBase = filepath.Join(userHome, ".config")
	}
	if _, err := exec.LookPath("systemctl"); err == nil {
		_ = exec.Command("systemctl", "--user", "disable", "--now", "codex-proxy-guardian.service").Run()
		_ = os.Remove(filepath.Join(configBase, "systemd", "user", "codex-proxy-guardian.service"))
		_ = exec.Command("systemctl", "--user", "daemon-reload").Run()
	}
	_ = os.Remove(filepath.Join(configBase, "autostart", "codex-proxy-guardian.desktop"))
	stopRecordedLinuxDaemon()
	return nil
}

func stopRecordedLinuxDaemon() {
	path, err := daemonPIDPath()
	if err != nil {
		return
	}
	content, err := os.ReadFile(path)
	if err != nil {
		return
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(content)))
	if err != nil || pid < 2 {
		return
	}
	running, err := filepath.EvalSymlinks(fmt.Sprintf("/proc/%d/exe", pid))
	if err != nil {
		_ = os.Remove(path)
		return
	}
	current, err := os.Executable()
	if err != nil {
		return
	}
	current, err = filepath.EvalSymlinks(current)
	if err != nil || filepath.Clean(running) != filepath.Clean(current) {
		return
	}
	_ = syscall.Kill(pid, syscall.SIGTERM)
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(fmt.Sprintf("/proc/%d", pid)); errors.Is(err, os.ErrNotExist) {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	_ = os.Remove(path)
}

func quoteDesktopArgument(value string) string {
	replacer := strings.NewReplacer("\\", "\\\\", "\"", "\\\"", "`", "\\`", "$", "\\$")
	return fmt.Sprintf("\"%s\"", replacer.Replace(value))
}
