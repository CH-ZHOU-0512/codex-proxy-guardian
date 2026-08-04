package guardian

import (
	"os"
	"os/exec"
	"strings"
)

func preferredProcess(name string, patterns []string) bool {
	name = strings.ToLower(name)
	for _, pattern := range patterns {
		pattern = strings.ToLower(strings.Trim(pattern, "* "))
		if pattern != "" && strings.Contains(name, pattern) {
			return true
		}
	}
	return false
}

func commandExists(name string) bool {
	if strings.TrimSpace(name) == "" {
		return false
	}
	_, err := exec.LookPath(name)
	return err == nil
}

func proxyEnvironment(proxyURI, noProxy string) []string {
	filtered := []string{}
	for _, entry := range os.Environ() {
		name := strings.ToUpper(strings.SplitN(entry, "=", 2)[0])
		if name == "HTTP_PROXY" || name == "HTTPS_PROXY" || name == "ALL_PROXY" || name == "NO_PROXY" {
			continue
		}
		filtered = append(filtered, entry)
	}
	return append(filtered,
		"HTTP_PROXY="+proxyURI, "HTTPS_PROXY="+proxyURI, "ALL_PROXY="+proxyURI,
		"http_proxy="+proxyURI, "https_proxy="+proxyURI, "all_proxy="+proxyURI,
		"NO_PROXY="+noProxy, "no_proxy="+noProxy)
}

func chromiumProxyURI(proxyURI string) string {
	if strings.HasPrefix(strings.ToLower(proxyURI), "socks5h://") {
		return "socks5://" + proxyURI[len("socks5h://"):]
	}
	return proxyURI
}
