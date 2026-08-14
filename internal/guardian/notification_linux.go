//go:build linux

package guardian

import (
	"fmt"
	"os/exec"
	"strings"
)

func notifyAutomaticUpdate(previousVersion, installedVersion string) error {
	title, message := automaticUpdateNotificationText(previousVersion, installedVersion)
	failures := []string{}
	if path, err := exec.LookPath("notify-send"); err == nil {
		if err := exec.Command(path, "--app-name=Codex Proxy Guardian", "--icon=software-update-available", "--expire-time=10000", title, message).Run(); err == nil {
			return nil
		} else {
			failures = append(failures, "notify-send: "+err.Error())
		}
	}
	if path, err := exec.LookPath("zenity"); err == nil {
		if err := exec.Command(path, "--notification", "--text="+title+"\n"+message).Run(); err == nil {
			return nil
		} else {
			failures = append(failures, "zenity: "+err.Error())
		}
	}
	if path, err := exec.LookPath("kdialog"); err == nil {
		if err := exec.Command(path, "--title", title, "--passivepopup", message, "10").Run(); err == nil {
			return nil
		} else {
			failures = append(failures, "kdialog: "+err.Error())
		}
	}
	if len(failures) == 0 {
		return fmt.Errorf("no supported desktop notification command is available")
	}
	return fmt.Errorf("desktop notification commands failed: %s", strings.Join(failures, "; "))
}
