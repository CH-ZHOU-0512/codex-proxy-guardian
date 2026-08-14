//go:build darwin

package guardian

import (
	"fmt"
	"os/exec"
	"strings"
)

func notifyAutomaticUpdate(previousVersion, installedVersion string) error {
	title, message := automaticUpdateNotificationText(previousVersion, installedVersion)
	escape := func(value string) string {
		return strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(value)
	}
	script := fmt.Sprintf(`display notification "%s" with title "%s"`, escape(message), escape(title))
	return exec.Command("osascript", "-e", script).Run()
}
