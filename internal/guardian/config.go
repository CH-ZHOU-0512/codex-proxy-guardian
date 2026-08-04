package guardian

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

type Config struct {
	SchemaVersion                      int      `json:"SchemaVersion"`
	Mode                               string   `json:"Mode"`
	AutomaticUpdates                   bool     `json:"AutomaticUpdates"`
	UpdateChannel                      string   `json:"UpdateChannel"`
	PollSeconds                        int      `json:"PollSeconds"`
	StableSamples                      int      `json:"StableSamples"`
	DebounceSeconds                    int      `json:"DebounceSeconds"`
	SafeRepairExternalCodexLaunches    bool     `json:"SafeRepairExternalCodexLaunches"`
	SafeExternalLaunchGraceSeconds     int      `json:"SafeExternalLaunchGraceSeconds"`
	ExternalLaunchDebounceSeconds      int      `json:"ExternalLaunchDebounceSeconds"`
	RestartCooldownSeconds             int      `json:"RestartCooldownSeconds"`
	RestartLimitCount                  int      `json:"RestartLimitCount"`
	RestartLimitWindowMinutes          int      `json:"RestartLimitWindowMinutes"`
	CircuitBreakerMinutes              int      `json:"CircuitBreakerMinutes"`
	GracefulCloseSeconds               int      `json:"GracefulCloseSeconds"`
	TCPTimeoutMilliseconds             int      `json:"TcpTimeoutMilliseconds"`
	HTTPTimeoutSeconds                 int      `json:"HttpTimeoutSeconds"`
	HTTPValidationIntervalSeconds      int      `json:"HttpValidationIntervalSeconds"`
	ProxyTestURLs                      []string `json:"ProxyTestUrls"`
	MinimumSuccessfulProxyTests        int      `json:"MinimumSuccessfulProxyTests"`
	ExplicitProxy                      string   `json:"ExplicitProxy"`
	AllowNonLoopbackProxy              bool     `json:"AllowNonLoopbackProxy"`
	EnableEnvironmentProxyDiscovery    bool     `json:"EnableEnvironmentProxyDiscovery"`
	PreferredProxyProcesses            []string `json:"PreferredProxyProcesses"`
	PreferredProxyPorts                []int    `json:"PreferredProxyPorts"`
	NoProxy                            string   `json:"NoProxy"`
	MacApplicationPaths                []string `json:"MacApplicationPaths"`
	CodexCommand                       string   `json:"CodexCommand"`
	LaunchMacApplicationWhenNotRunning bool     `json:"LaunchMacApplicationWhenNotRunning"`
	LogRetentionDays                   int      `json:"LogRetentionDays"`
	MaxLogFiles                        int      `json:"MaxLogFiles"`
	MaxLogFileMB                       int      `json:"MaxLogFileMB"`
}

func DefaultConfig() Config {
	return Config{
		SchemaVersion: 1, Mode: "Safe", AutomaticUpdates: true, UpdateChannel: "Stable",
		PollSeconds: 5, StableSamples: 3, DebounceSeconds: 10,
		SafeRepairExternalCodexLaunches: true, SafeExternalLaunchGraceSeconds: 20,
		ExternalLaunchDebounceSeconds: 15, RestartCooldownSeconds: 45,
		RestartLimitCount: 3, RestartLimitWindowMinutes: 10, CircuitBreakerMinutes: 15,
		GracefulCloseSeconds: 10, TCPTimeoutMilliseconds: 1500, HTTPTimeoutSeconds: 8,
		HTTPValidationIntervalSeconds: 30,
		ProxyTestURLs:                 []string{"https://api.openai.com/v1/models", "https://chatgpt.com/", "https://auth.openai.com/"},
		MinimumSuccessfulProxyTests:   2, EnableEnvironmentProxyDiscovery: true,
		PreferredProxyProcesses: []string{"clash", "mihomo", "v2ray", "xray", "sing-box", "singbox", "shadowsocks", "nekoray", "nekobox", "hiddify", "flclash"},
		PreferredProxyPorts:     []int{7890, 7891, 7892, 7893, 7894, 7895, 7896, 7897, 1080, 10808, 10809, 2080, 8080},
		NoProxy:                 "localhost,127.0.0.1,::1",
		MacApplicationPaths: []string{
			"/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
			"~/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
			"/Applications/Codex.app/Contents/MacOS/Codex",
			"~/Applications/Codex.app/Contents/MacOS/Codex",
		},
		CodexCommand: "codex", LaunchMacApplicationWhenNotRunning: false,
		LogRetentionDays: 14, MaxLogFiles: 20, MaxLogFileMB: 5,
	}
}

func LoadConfig() (Config, error) {
	cfg := DefaultConfig()
	path, err := configPath()
	if err != nil {
		return cfg, err
	}
	content, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			return cfg, err
		}
		if err := writeJSONAtomic(path, cfg, 0o600); err != nil {
			return cfg, err
		}
		return cfg, nil
	}
	if err != nil {
		return cfg, err
	}
	if err := json.Unmarshal(content, &cfg); err != nil {
		return cfg, fmt.Errorf("parse config: %w", err)
	}
	if err := cfg.Validate(); err != nil {
		return cfg, err
	}
	return cfg, nil
}

func (cfg Config) Validate() error {
	if cfg.Mode != "Safe" && cfg.Mode != "Enforce" {
		return errors.New("Mode must be Safe or Enforce")
	}
	if cfg.PollSeconds < 2 || cfg.PollSeconds > 300 || cfg.StableSamples < 1 || cfg.StableSamples > 100 {
		return errors.New("PollSeconds or StableSamples is outside the safe range")
	}
	if cfg.MinimumSuccessfulProxyTests < 1 || cfg.MinimumSuccessfulProxyTests > len(cfg.ProxyTestURLs) {
		return errors.New("MinimumSuccessfulProxyTests must fit ProxyTestUrls")
	}
	if cfg.RestartLimitCount < 1 || cfg.RestartLimitWindowMinutes < 1 || cfg.CircuitBreakerMinutes < 1 {
		return errors.New("restart circuit breaker values must be positive")
	}
	return nil
}

func SetMode(mode string) error {
	cfg, err := LoadConfig()
	if err != nil {
		return err
	}
	switch strings.ToLower(strings.TrimSpace(mode)) {
	case "auto", "safe":
		cfg.Mode = "Safe"
	case "strict", "enforce":
		cfg.Mode = "Enforce"
	default:
		return errors.New("mode must be auto or strict")
	}
	path, _ := configPath()
	return writeJSONAtomic(path, cfg, 0o600)
}

func configPath() (string, error) {
	if override := strings.TrimSpace(os.Getenv("CPG_HOME")); override != "" {
		return filepath.Join(override, "config.json"), nil
	}
	userHome, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	if runtime.GOOS == "darwin" {
		return filepath.Join(userHome, "Library", "Application Support", "CodexProxyGuardian", "config.json"), nil
	}
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" {
		base = filepath.Join(userHome, ".config")
	}
	return filepath.Join(base, "codex-proxy-guardian", "config.json"), nil
}
