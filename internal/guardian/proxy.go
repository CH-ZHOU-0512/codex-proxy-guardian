package guardian

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

type Candidate struct {
	URI                  string `json:"uri"`
	Source               string `json:"source"`
	Score                int    `json:"score"`
	AllowNonLoopbackHost bool   `json:"-"`
}

type Validation struct {
	Valid          bool      `json:"valid"`
	Successful     int       `json:"successfulTests"`
	TargetCount    int       `json:"targetCount"`
	CheckedAt      time.Time `json:"checkedAt"`
	LastErrorClass string    `json:"lastErrorClass,omitempty"`
}

var inheritedProxyEnvironment = snapshotProxyEnvironment()

func snapshotProxyEnvironment() map[string]string {
	values := map[string]string{}
	for _, name := range []string{"HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "https_proxy", "http_proxy", "all_proxy"} {
		if value := strings.TrimSpace(os.Getenv(name)); value != "" {
			values[name] = value
		}
	}
	return values
}

func NormalizeProxy(value string, allowNonLoopback bool) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", fmt.Errorf("empty proxy")
	}
	if !strings.Contains(value, "://") {
		value = "http://" + value
	}
	parsed, err := url.Parse(value)
	if err != nil || parsed.Host == "" {
		return "", fmt.Errorf("invalid proxy URL")
	}
	parsed.Scheme = strings.ToLower(parsed.Scheme)
	if parsed.Scheme == "socks" || parsed.Scheme == "socks5" {
		parsed.Scheme = "socks5h"
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" && parsed.Scheme != "socks5h" {
		return "", fmt.Errorf("only HTTP, HTTPS and SOCKS5 proxies are supported")
	}
	if parsed.User != nil || parsed.Path != "" || parsed.RawQuery != "" || parsed.Fragment != "" {
		return "", fmt.Errorf("proxy credentials, paths, queries and fragments are rejected")
	}
	port, err := strconv.Atoi(parsed.Port())
	if err != nil || port < 1 || port > 65535 {
		return "", fmt.Errorf("proxy must include an explicit port")
	}
	host := strings.ToLower(parsed.Hostname())
	if !allowNonLoopback && host != "localhost" && !net.ParseIP(host).IsLoopback() {
		return "", fmt.Errorf("non-loopback proxy requires explicit opt-in")
	}
	return (&url.URL{Scheme: parsed.Scheme, Host: net.JoinHostPort(host, strconv.Itoa(port))}).String(), nil
}

func DiscoverCandidates(cfg Config, preferred string) []Candidate {
	all := []Candidate{}
	appendCandidate := func(raw, source string, score int, allowSystemHost bool) {
		normalized, err := NormalizeProxy(raw, cfg.AllowNonLoopbackProxy || allowSystemHost)
		if err == nil {
			all = append(all, Candidate{URI: normalized, Source: source, Score: score})
		}
	}
	appendCandidate(cfg.ExplicitProxy, "config:explicit", 500, false)
	for _, candidate := range platformSystemProxyCandidates(cfg) {
		appendCandidate(candidate.URI, candidate.Source, candidate.Score, candidate.AllowNonLoopbackHost)
	}
	if cfg.EnablePACDiscovery {
		for _, candidate := range discoverPACCandidates(cfg) {
			appendCandidate(candidate.URI, candidate.Source, candidate.Score, candidate.AllowNonLoopbackHost)
		}
	}
	if cfg.EnableEnvironmentProxyDiscovery {
		for _, name := range []string{"HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "https_proxy", "http_proxy", "all_proxy"} {
			appendCandidate(inheritedProxyEnvironment[name], "environment:"+name, 250, false)
		}
	}
	for _, candidate := range platformListenerCandidates(cfg) {
		appendCandidate(candidate.URI, candidate.Source, candidate.Score, false)
	}
	for _, port := range cfg.PreferredProxyPorts {
		appendCandidate(fmt.Sprintf("http://127.0.0.1:%d", port), "loopback:common-port", 100, false)
		appendCandidate(fmt.Sprintf("socks5h://127.0.0.1:%d", port), "loopback:common-port-socks5", 95, false)
	}

	deduplicated := map[string]Candidate{}
	for _, candidate := range all {
		current, exists := deduplicated[candidate.URI]
		if !exists || candidate.Score > current.Score {
			deduplicated[candidate.URI] = candidate
		}
	}
	result := make([]Candidate, 0, len(deduplicated))
	for _, candidate := range deduplicated {
		result = append(result, candidate)
	}
	sort.Slice(result, func(i, j int) bool {
		if result[i].Score != result[j].Score {
			return result[i].Score > result[j].Score
		}
		if result[i].URI == preferred {
			return true
		}
		if result[j].URI == preferred {
			return false
		}
		return result[i].URI < result[j].URI
	})
	return result
}

func ValidateCandidate(ctx context.Context, candidate Candidate, cfg Config) Validation {
	checkedAt := time.Now().UTC()
	proxyURL, err := url.Parse(candidate.URI)
	if err != nil {
		return Validation{CheckedAt: checkedAt, TargetCount: len(cfg.ProxyTestURLs), LastErrorClass: "proxy_parse"}
	}
	dialer := &net.Dialer{Timeout: time.Duration(cfg.TCPTimeoutMilliseconds) * time.Millisecond}
	connection, err := dialer.DialContext(ctx, "tcp", proxyURL.Host)
	if err != nil {
		return Validation{CheckedAt: checkedAt, TargetCount: len(cfg.ProxyTestURLs), LastErrorClass: "tcp_connect"}
	}
	_ = connection.Close()

	transport := &http.Transport{
		Proxy: http.ProxyURL(proxyURL), DialContext: dialer.DialContext,
		TLSHandshakeTimeout:   time.Duration(cfg.HTTPTimeoutSeconds) * time.Second,
		ResponseHeaderTimeout: time.Duration(cfg.HTTPTimeoutSeconds) * time.Second,
		DisableKeepAlives:     true,
	}
	client := &http.Client{Transport: transport, Timeout: time.Duration(cfg.HTTPTimeoutSeconds) * time.Second}
	successful := 0
	lastClass := "http_request"
	for _, target := range cfg.ProxyTestURLs {
		request, requestErr := http.NewRequestWithContext(ctx, http.MethodHead, target, nil)
		if requestErr != nil {
			lastClass = "target_parse"
			continue
		}
		request.Header.Set("User-Agent", "CodexProxyGuardian/"+Version)
		response, requestErr := client.Do(request)
		if requestErr != nil {
			continue
		}
		_ = response.Body.Close()
		if response.StatusCode >= 100 && response.StatusCode < 500 && response.StatusCode != http.StatusProxyAuthRequired {
			successful++
		}
	}
	transport.CloseIdleConnections()
	valid := successful >= cfg.MinimumSuccessfulProxyTests
	if valid {
		lastClass = ""
	}
	return Validation{Valid: valid, Successful: successful, TargetCount: len(cfg.ProxyTestURLs), CheckedAt: checkedAt, LastErrorClass: lastClass}
}
