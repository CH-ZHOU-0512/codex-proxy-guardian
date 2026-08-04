//go:build darwin

package guardian

import (
	"fmt"
	"html"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
)

const macServiceLabel = "io.github.ch-zhou-0512.codex-proxy-guardian"

func platformInstallUserService(binary string) error {
	userHome, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	data, err := dataRoot()
	if err != nil {
		return err
	}
	logs := filepath.Join(data, "logs")
	if err := os.MkdirAll(logs, 0o700); err != nil {
		return err
	}
	path := filepath.Join(userHome, "Library", "LaunchAgents", macServiceLabel+".plist")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	plist := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>%s</string>
<key>ProgramArguments</key><array><string>%s</string><string>daemon</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ProcessType</key><string>Background</string>
<key>StandardOutPath</key><string>%s</string><key>StandardErrorPath</key><string>%s</string>
</dict></plist>
`, macServiceLabel, html.EscapeString(binary), html.EscapeString(filepath.Join(logs, "service.out.log")), html.EscapeString(filepath.Join(logs, "service.err.log")))
	if err := os.WriteFile(path, []byte(plist), 0o600); err != nil {
		return err
	}
	domain := "gui/" + strconv.Itoa(os.Getuid())
	_ = exec.Command("launchctl", "bootout", domain, path).Run()
	if output, err := exec.Command("launchctl", "bootstrap", domain, path).CombinedOutput(); err != nil {
		return fmt.Errorf("launchctl bootstrap failed: %s", string(output))
	}
	_ = exec.Command("launchctl", "kickstart", "-k", domain+"/"+macServiceLabel).Run()
	return nil
}

func platformUninstallUserService() error {
	userHome, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	path := filepath.Join(userHome, "Library", "LaunchAgents", macServiceLabel+".plist")
	domain := "gui/" + strconv.Itoa(os.Getuid())
	_ = exec.Command("launchctl", "bootout", domain, path).Run()
	err = os.Remove(path)
	if os.IsNotExist(err) {
		return nil
	}
	return err
}
