package guardian

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

func dataRoot() (string, error) {
	if override := strings.TrimSpace(os.Getenv("CPG_HOME")); override != "" {
		return filepath.Clean(override), nil
	}
	userHome, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	if runtime.GOOS == "darwin" {
		return filepath.Join(userHome, "Library", "Application Support", "CodexProxyGuardian"), nil
	}
	base := os.Getenv("XDG_STATE_HOME")
	if base == "" {
		base = filepath.Join(userHome, ".local", "state")
	}
	return filepath.Join(base, "codex-proxy-guardian"), nil
}

func writeJSONAtomic(path string, value any, mode os.FileMode) error {
	encoded, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	encoded = append(encoded, '\n')
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".cpg-*.tmp")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(mode); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(encoded); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporaryPath, path)
}

type Logger struct {
	root string
	cfg  Config
}

func NewLogger(cfg Config) (*Logger, error) {
	root, err := dataRoot()
	if err != nil {
		return nil, err
	}
	root = filepath.Join(root, "logs")
	if err := os.MkdirAll(root, 0o700); err != nil {
		return nil, err
	}
	logger := &Logger{root: root, cfg: cfg}
	logger.prune()
	return logger, nil
}

func (logger *Logger) Log(level, event, message string, fields map[string]any) {
	record := map[string]any{"timestamp": time.Now().UTC().Format(time.RFC3339Nano), "level": level, "event": event, "message": message}
	for key, value := range fields {
		record[key] = value
	}
	encoded, _ := json.Marshal(record)
	path := filepath.Join(logger.root, "guardian-"+time.Now().Format("2006-01-02")+".jsonl")
	if info, err := os.Stat(path); err == nil && info.Size() >= int64(logger.cfg.MaxLogFileMB)*1024*1024 {
		_ = os.Remove(path + ".1")
		_ = os.Rename(path, path+".1")
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	_, _ = fmt.Fprintln(file, string(encoded))
	_ = file.Close()
}

func (logger *Logger) prune() {
	entries, _ := os.ReadDir(logger.root)
	cutoff := time.Now().Add(-time.Duration(logger.cfg.LogRetentionDays) * 24 * time.Hour)
	kept := 0
	for index := len(entries) - 1; index >= 0; index-- {
		entry := entries[index]
		if entry.IsDir() {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		kept++
		if info.ModTime().Before(cutoff) || kept > logger.cfg.MaxLogFiles {
			_ = os.Remove(filepath.Join(logger.root, entry.Name()))
		}
	}
}
