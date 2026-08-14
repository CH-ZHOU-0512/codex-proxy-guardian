package guardian

import "strings"

func shouldNotifyAutomaticUpdate(previousVersion, installedVersion, lastNotifiedVersion string) bool {
	previous := strings.TrimPrefix(strings.TrimSpace(previousVersion), "v")
	installed := strings.TrimPrefix(strings.TrimSpace(installedVersion), "v")
	lastNotified := strings.TrimPrefix(strings.TrimSpace(lastNotifiedVersion), "v")
	return previous != "" && installed != "" && previous != installed && lastNotified != installed
}

func automaticUpdateNotificationText(previousVersion, installedVersion string) (string, string) {
	previous := strings.TrimPrefix(strings.TrimSpace(previousVersion), "v")
	installed := strings.TrimPrefix(strings.TrimSpace(installedVersion), "v")
	title := "Codex Proxy Guardian 已更新到 v" + installed
	message := "自动更新已经完成。Codex 无需重启，可以继续使用。"
	if previous != "" {
		message = "已从 v" + previous + " 自动更新到 v" + installed + "。Codex 无需重启，可以继续使用。"
	}
	return title, message
}
