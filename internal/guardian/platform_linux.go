//go:build linux

package guardian

import (
	"fmt"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
)

type linuxManager struct{ cfg Config }

func newPlatformManager(cfg Config) platformManager { return &linuxManager{cfg: cfg} }

func (manager *linuxManager) TargetName() string { return "Codex CLI" }
func (manager *linuxManager) Observe(string) AppObservation {
	return AppObservation{Available: commandExists(manager.cfg.CodexCommand)}
}
func (manager *linuxManager) Launch(proxyURI string, arguments []string) error {
	return execCodexCLI(manager.cfg, proxyURI, arguments)
}
func (manager *linuxManager) Restart(string, Config) error {
	return fmt.Errorf("Linux terminal sessions are never restarted automatically; launch with codex-guard")
}

func platformSystemProxyCandidates(cfg Config) []Candidate {
	mode, err := exec.Command("gsettings", "get", "org.gnome.system.proxy", "mode").Output()
	if err != nil || !strings.Contains(string(mode), "manual") {
		return nil
	}
	result := []Candidate{}
	for _, scheme := range []string{"https", "http", "socks"} {
		hostOutput, hostErr := exec.Command("gsettings", "get", "org.gnome.system.proxy."+scheme, "host").Output()
		portOutput, portErr := exec.Command("gsettings", "get", "org.gnome.system.proxy."+scheme, "port").Output()
		if hostErr != nil || portErr != nil {
			continue
		}
		host := strings.Trim(strings.TrimSpace(string(hostOutput)), "'\"")
		port, parseErr := strconv.Atoi(strings.TrimSpace(string(portOutput)))
		if host != "" && parseErr == nil && port > 0 {
			proxyScheme := "http"
			if scheme == "socks" {
				proxyScheme = "socks5h"
			}
			result = append(result, Candidate{URI: fmt.Sprintf("%s://%s:%d", proxyScheme, host, port), Source: "system:gnome-" + scheme, Score: 300, AllowNonLoopbackHost: cfg.AllowSystemNonLoopbackProxy})
		}
	}
	return result
}

func platformPACSources(cfg Config) []pacSource {
	mode, err := exec.Command("gsettings", "get", "org.gnome.system.proxy", "mode").Output()
	if err != nil || !strings.Contains(string(mode), "auto") {
		return nil
	}
	configured, configuredErr := exec.Command("gsettings", "get", "org.gnome.system.proxy", "autoconfig-url").Output()
	if configuredErr == nil {
		pacURL := strings.Trim(strings.TrimSpace(string(configured)), "'\"")
		if pacURL != "" {
			return []pacSource{{URL: pacURL, Source: "system:gnome-pac", Score: 420, AllowNonLoopbackHost: cfg.AllowSystemNonLoopbackProxy}}
		}
	}
	if cfg.EnableWPADDiscovery {
		return []pacSource{{URL: "http://wpad/wpad.dat", Source: "system:gnome-wpad", Score: 410, AllowNonLoopbackHost: cfg.AllowSystemNonLoopbackProxy}}
	}
	return nil
}

var linuxListenerPattern = regexp.MustCompile(`(?i)(127\.0\.0\.1|\[::1\]|::1):(\d+).*users:\(\(\"?([^\",)]+)`) // ss -ltnpH

func platformListenerCandidates(cfg Config) []Candidate {
	output, err := exec.Command("ss", "-ltnpH").CombinedOutput()
	if err != nil {
		return nil
	}
	result := []Candidate{}
	for _, line := range strings.Split(string(output), "\n") {
		match := linuxListenerPattern.FindStringSubmatch(line)
		if len(match) != 4 || !preferredProcess(match[3], cfg.PreferredProxyProcesses) {
			continue
		}
		host := strings.Trim(match[1], "[]")
		result = append(result,
			Candidate{URI: fmt.Sprintf("http://%s:%s", host, match[2]), Source: "process:" + strings.ToLower(match[3]), Score: 200},
			Candidate{URI: fmt.Sprintf("socks5h://%s:%s", host, match[2]), Source: "process:" + strings.ToLower(match[3]) + ":socks5", Score: 195},
		)
	}
	return result
}
