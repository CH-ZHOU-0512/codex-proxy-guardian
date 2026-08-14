package guardian

import (
	"strings"
	"testing"
)

func TestAutomaticUpdateNotificationDecision(t *testing.T) {
	if !shouldNotifyAutomaticUpdate("1.5.3", "1.5.4", "") {
		t.Fatal("a newly installed version should be announced")
	}
	if shouldNotifyAutomaticUpdate("1.5.3", "1.5.4", "1.5.4") {
		t.Fatal("the same installed version should not be announced twice")
	}
	if shouldNotifyAutomaticUpdate("1.5.4", "1.5.4", "") {
		t.Fatal("a normal daemon restart should not look like an update")
	}
}

func TestAutomaticUpdateNotificationIsPlainLanguage(t *testing.T) {
	title, message := automaticUpdateNotificationText("v1.5.3", "v1.5.4")
	for _, expected := range []string{"v1.5.4", "Codex 无需重启"} {
		if !strings.Contains(title+message, expected) {
			t.Fatalf("notification is missing %q: %s %s", expected, title, message)
		}
	}
}
