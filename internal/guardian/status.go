package guardian

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"time"
)

var Version = "dev"

type Status struct {
	SchemaVersion       int        `json:"schemaVersion"`
	Version             string     `json:"version"`
	Platform            string     `json:"platform"`
	Target              string     `json:"target"`
	GuardianState       string     `json:"guardianState"`
	Mode                string     `json:"mode"`
	ActiveProxy         string     `json:"activeProxy,omitempty"`
	ActiveSource        string     `json:"activeSource,omitempty"`
	ActiveProxyValid    bool       `json:"activeProxyValid"`
	Validation          Validation `json:"validation"`
	LaunchConfigured    bool       `json:"launchConfigured"`
	TrafficObserved     bool       `json:"trafficObserved"`
	ApplicationRunning  bool       `json:"applicationRunning"`
	CircuitBreakerUntil *time.Time `json:"circuitBreakerUntil,omitempty"`
	RecentRestartCount  int        `json:"recentRestartCount"`
	LastUpdated         time.Time  `json:"lastUpdated"`
	LastErrorClass      string     `json:"lastErrorClass,omitempty"`
}

func statusPath() (string, error) {
	root, err := dataRoot()
	return filepath.Join(root, "status.json"), err
}

func ReadStatus() (Status, error) {
	path, err := statusPath()
	if err != nil {
		return Status{}, err
	}
	content, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		cfg, _ := LoadConfig()
		return Status{SchemaVersion: 1, Version: Version, Platform: runtime.GOOS, Target: newPlatformManager(cfg).TargetName(), GuardianState: "NotRunning", Mode: cfg.Mode}, nil
	}
	if err != nil {
		return Status{}, err
	}
	var status Status
	if err := json.Unmarshal(content, &status); err != nil {
		return status, err
	}
	return status, nil
}

func saveStatus(status Status) error {
	path, err := statusPath()
	if err != nil {
		return err
	}
	return writeJSONAtomic(path, status, 0o600)
}

func PrintStatus(writer io.Writer, status Status) {
	fmt.Fprintf(writer, "Codex Proxy Guardian %s (%s)\n", status.Version, status.Platform)
	fmt.Fprintf(writer, "State: %s\nTarget: %s\nMode: %s\n", status.GuardianState, status.Target, status.Mode)
	if status.ActiveProxy != "" {
		fmt.Fprintf(writer, "Proxy: %s (%s)\nValidated: %t (%d/%d)\n", status.ActiveProxy, status.ActiveSource, status.ActiveProxyValid, status.Validation.Successful, status.Validation.TargetCount)
	}
	fmt.Fprintf(writer, "Launch configured: %t\nTraffic observed: %t\n", status.LaunchConfigured, status.TrafficObserved)
}

type DoctorReport struct {
	SafeForSharing bool     `json:"safeForSharing"`
	Version        string   `json:"version"`
	Platform       string   `json:"platform"`
	Architecture   string   `json:"architecture"`
	GuardianState  string   `json:"guardianState"`
	Mode           string   `json:"mode"`
	ProxyValidated bool     `json:"proxyValidated"`
	CandidateCount int      `json:"candidateCount"`
	Target         string   `json:"target"`
	Notes          []string `json:"notes"`
}

func Doctor() (DoctorReport, error) {
	cfg, err := LoadConfig()
	if err != nil {
		return DoctorReport{}, err
	}
	manager := newPlatformManager(cfg)
	status, _ := ReadStatus()
	report := DoctorReport{
		SafeForSharing: true, Version: Version, Platform: runtime.GOOS, Architecture: runtime.GOARCH,
		GuardianState: status.GuardianState, Mode: cfg.Mode, ProxyValidated: status.ActiveProxyValid,
		CandidateCount: len(DiscoverCandidates(cfg, "")), Target: manager.TargetName(),
	}
	if runtime.GOOS == "linux" {
		report.Notes = append(report.Notes, "Linux has no official Codex desktop app; use codex-guard for the Codex CLI.")
	}
	return report, nil
}
