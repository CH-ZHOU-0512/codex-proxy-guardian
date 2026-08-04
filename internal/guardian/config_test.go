package guardian

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestLoadConfigBackfillsPACDefaultsForExistingInstall(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CPG_HOME", home)
	legacy := DefaultConfig()
	encoded, err := json.Marshal(legacy)
	if err != nil {
		t.Fatal(err)
	}
	var values map[string]any
	if err := json.Unmarshal(encoded, &values); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{
		"ExplicitPAC", "AllowSystemNonLoopbackProxy", "EnablePACDiscovery", "EnableWPADDiscovery",
		"PacFetchTimeoutSeconds", "PacExecutionTimeoutMilliseconds", "PacMaxBytes", "PacCacheMinutes",
	} {
		delete(values, name)
	}
	encoded, err = json.Marshal(values)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, "config.json"), encoded, 0o600); err != nil {
		t.Fatal(err)
	}
	loaded, err := LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if !loaded.EnablePACDiscovery || !loaded.EnableWPADDiscovery || !loaded.AllowSystemNonLoopbackProxy {
		t.Fatalf("PAC compatibility defaults were not backfilled: %#v", loaded)
	}
	if loaded.PACFetchTimeoutSeconds != 5 || loaded.PACExecutionTimeoutMilliseconds != 500 || loaded.PACMaxBytes != 1048576 || loaded.PACCacheMinutes != 5 {
		t.Fatalf("PAC safety defaults were not backfilled: %#v", loaded)
	}
}
