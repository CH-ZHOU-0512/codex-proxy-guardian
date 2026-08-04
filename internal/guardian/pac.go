package guardian

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/dop251/goja"
)

type pacSource struct {
	URL                  string
	Source               string
	Score                int
	AllowNonLoopbackHost bool
}

type pacDocumentCacheEntry struct {
	Script    string
	FetchedAt time.Time
}

var pacDocumentCache = struct {
	sync.Mutex
	items map[string]pacDocumentCacheEntry
}{items: map[string]pacDocumentCacheEntry{}}

func discoverPACCandidates(cfg Config) []Candidate {
	sources := []pacSource{}
	if explicit := strings.TrimSpace(cfg.ExplicitPAC); explicit != "" {
		sources = append(sources, pacSource{URL: explicit, Source: "config:explicit-pac", Score: 480, AllowNonLoopbackHost: cfg.AllowNonLoopbackProxy})
	}
	sources = append(sources, platformPACSources(cfg)...)
	seenSources := map[string]bool{}
	result := []Candidate{}
	for _, source := range sources {
		pacURL, err := normalizePACURL(source.URL)
		if err != nil || seenSources[pacURL] {
			continue
		}
		seenSources[pacURL] = true
		script, err := loadPACDocument(pacURL, cfg)
		if err != nil {
			continue
		}
		for targetIndex, target := range cfg.ProxyTestURLs {
			routes, evaluateErr := evaluatePAC(script, target, cfg)
			if evaluateErr != nil {
				continue
			}
			for routeIndex, route := range routes {
				result = append(result, Candidate{
					URI: route, Source: source.Source + ":target-" + strconv.Itoa(targetIndex+1),
					Score: source.Score - targetIndex - routeIndex, AllowNonLoopbackHost: source.AllowNonLoopbackHost,
				})
			}
		}
	}
	return result
}

func normalizePACURL(raw string) (string, error) {
	raw = strings.TrimSpace(strings.Trim(raw, "\"'"))
	if raw == "" {
		return "", fmt.Errorf("empty PAC URL")
	}
	if !strings.Contains(raw, "://") {
		if filepath.IsAbs(raw) {
			return (&url.URL{Scheme: "file", Path: filepath.ToSlash(raw)}).String(), nil
		}
		return "", fmt.Errorf("PAC must be an absolute http, https or file URL")
	}
	parsed, err := url.Parse(raw)
	if err != nil || (parsed.Scheme != "file" && parsed.Host == "") {
		return "", fmt.Errorf("invalid PAC URL")
	}
	parsed.Scheme = strings.ToLower(parsed.Scheme)
	if parsed.Scheme != "http" && parsed.Scheme != "https" && parsed.Scheme != "file" {
		return "", fmt.Errorf("unsupported PAC URL scheme")
	}
	if parsed.User != nil || parsed.Fragment != "" {
		return "", fmt.Errorf("PAC credentials and fragments are rejected")
	}
	return parsed.String(), nil
}

func loadPACDocument(pacURL string, cfg Config) (string, error) {
	pacDocumentCache.Lock()
	cached, exists := pacDocumentCache.items[pacURL]
	if exists && time.Since(cached.FetchedAt) < time.Duration(cfg.PACCacheMinutes)*time.Minute {
		pacDocumentCache.Unlock()
		return cached.Script, nil
	}
	pacDocumentCache.Unlock()

	parsed, err := url.Parse(pacURL)
	if err != nil {
		return "", err
	}
	var reader io.ReadCloser
	if parsed.Scheme == "file" {
		path, pathErr := url.PathUnescape(parsed.Path)
		if pathErr != nil {
			return "", pathErr
		}
		if runtime.GOOS == "windows" && len(path) >= 3 && path[0] == '/' && path[2] == ':' {
			path = path[1:]
		}
		file, openErr := os.Open(filepath.FromSlash(path))
		if openErr != nil {
			return "", openErr
		}
		reader = file
	} else {
		transport := &http.Transport{Proxy: nil, DisableKeepAlives: true}
		client := &http.Client{Transport: transport, Timeout: time.Duration(cfg.PACFetchTimeoutSeconds) * time.Second}
		request, requestErr := http.NewRequest(http.MethodGet, pacURL, nil)
		if requestErr != nil {
			return "", requestErr
		}
		request.Header.Set("User-Agent", "CodexProxyGuardian/"+Version)
		response, requestErr := client.Do(request)
		if requestErr != nil {
			return "", requestErr
		}
		if response.StatusCode < 200 || response.StatusCode >= 300 {
			_ = response.Body.Close()
			return "", fmt.Errorf("PAC download returned HTTP %d", response.StatusCode)
		}
		reader = response.Body
	}
	defer reader.Close()
	content, err := io.ReadAll(io.LimitReader(reader, int64(cfg.PACMaxBytes)+1))
	if err != nil {
		return "", err
	}
	if len(content) == 0 || len(content) > cfg.PACMaxBytes {
		return "", fmt.Errorf("PAC document is empty or exceeds the configured limit")
	}
	script := strings.TrimPrefix(string(content), "\ufeff")
	pacDocumentCache.Lock()
	pacDocumentCache.items[pacURL] = pacDocumentCacheEntry{Script: script, FetchedAt: time.Now()}
	pacDocumentCache.Unlock()
	return script, nil
}

func evaluatePAC(script, target string, cfg Config) ([]string, error) {
	targetURL, err := url.Parse(target)
	if err != nil || targetURL.Hostname() == "" {
		return nil, fmt.Errorf("invalid PAC target")
	}
	vm := goja.New()
	resolver := &net.Resolver{}
	resolve := func(host string) []string {
		ctx, cancel := context.WithTimeout(context.Background(), 750*time.Millisecond)
		defer cancel()
		addresses, lookupErr := resolver.LookupHost(ctx, strings.Trim(strings.TrimSpace(host), "[]"))
		if lookupErr != nil {
			return nil
		}
		sort.Strings(addresses)
		return addresses
	}
	_ = vm.Set("dnsResolve", func(host string) string {
		addresses := resolve(host)
		if len(addresses) == 0 {
			return ""
		}
		return addresses[0]
	})
	_ = vm.Set("dnsResolveEx", func(host string) string { return strings.Join(resolve(host), ";") })
	_ = vm.Set("isResolvable", func(host string) bool { return len(resolve(host)) > 0 })
	_ = vm.Set("isResolvableEx", func(host string) bool { return len(resolve(host)) > 0 })
	_ = vm.Set("isInNet", func(host, pattern, mask string) bool { return pacIsInNet(resolve, host, pattern, mask) })
	_ = vm.Set("isInNetEx", func(host, prefix string) bool { return pacIsInNetEx(resolve, host, prefix) })
	_ = vm.Set("myIpAddress", pacLocalAddress)
	_ = vm.Set("myIpAddressEx", pacLocalAddress)
	_ = vm.Set("sortIpAddressList", func(value string) string { return value })
	_ = vm.Set("getClientVersion", func() string { return "1.0" })
	_ = vm.Set("alert", func(string) {})

	timer := time.AfterFunc(time.Duration(cfg.PACExecutionTimeoutMilliseconds)*time.Millisecond, func() {
		vm.Interrupt("PAC execution timeout")
	})
	defer timer.Stop()
	if _, err := vm.RunString(pacPrelude + "\n" + script); err != nil {
		return nil, fmt.Errorf("execute PAC: %w", err)
	}
	function, ok := goja.AssertFunction(vm.Get("FindProxyForURL"))
	if !ok {
		return nil, fmt.Errorf("PAC does not define FindProxyForURL")
	}
	value, err := function(goja.Undefined(), vm.ToValue(target), vm.ToValue(targetURL.Hostname()))
	if err != nil {
		return nil, fmt.Errorf("evaluate PAC target: %w", err)
	}
	return parsePACResult(value.String()), nil
}

func parsePACResult(result string) []string {
	routes := []string{}
	for _, raw := range strings.Split(result, ";") {
		fields := strings.Fields(strings.TrimSpace(raw))
		if len(fields) < 1 || strings.EqualFold(fields[0], "DIRECT") || len(fields) < 2 {
			continue
		}
		address := fields[1]
		var candidate string
		switch strings.ToUpper(fields[0]) {
		case "PROXY", "HTTP":
			candidate = "http://" + address
		case "HTTPS":
			candidate = "https://" + address
		case "SOCKS", "SOCKS5":
			candidate = "socks5h://" + address
		default:
			continue
		}
		routes = append(routes, candidate)
	}
	return routes
}

func pacIsInNet(resolve func(string) []string, host, pattern, mask string) bool {
	ip := net.ParseIP(strings.Trim(host, "[]"))
	if ip == nil {
		for _, value := range resolve(host) {
			if parsed := net.ParseIP(value); parsed != nil && parsed.To4() != nil {
				ip = parsed
				break
			}
		}
	}
	ip, network, maskIP := ip.To4(), net.ParseIP(pattern).To4(), net.ParseIP(mask).To4()
	if ip == nil || network == nil || maskIP == nil {
		return false
	}
	for index := range ip {
		if ip[index]&maskIP[index] != network[index]&maskIP[index] {
			return false
		}
	}
	return true
}

func pacIsInNetEx(resolve func(string) []string, host, prefix string) bool {
	_, network, err := net.ParseCIDR(prefix)
	if err != nil {
		return false
	}
	values := []string{strings.Trim(host, "[]")}
	if net.ParseIP(values[0]) == nil {
		values = resolve(host)
	}
	for _, value := range values {
		if ip := net.ParseIP(value); ip != nil && network.Contains(ip) {
			return true
		}
	}
	return false
}

func pacLocalAddress() string {
	connection, err := net.DialTimeout("udp", "192.0.2.1:80", 250*time.Millisecond)
	if err == nil {
		defer connection.Close()
		if address, ok := connection.LocalAddr().(*net.UDPAddr); ok && address.IP != nil {
			return address.IP.String()
		}
	}
	return "127.0.0.1"
}

const pacPrelude = `
function isPlainHostName(host) { return host.indexOf('.') === -1; }
function dnsDomainIs(host, domain) { return host.length >= domain.length && host.slice(-domain.length) === domain; }
function localHostOrDomainIs(host, hostdom) { return host === hostdom || (host.indexOf('.') === -1 && hostdom.indexOf(host + '.') === 0); }
function dnsDomainLevels(host) { return (host.match(/\./g) || []).length; }
function shExpMatch(str, pattern) {
  var escaped = pattern.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.');
  return new RegExp('^' + escaped + '$').test(str);
}
function weekdayRange() {
  var args = Array.prototype.slice.call(arguments), gmt = String(args[args.length - 1]).toUpperCase() === 'GMT';
  if (gmt) args.pop();
  var days = ['SUN','MON','TUE','WED','THU','FRI','SAT'], now = new Date(), current = gmt ? now.getUTCDay() : now.getDay();
  var first = days.indexOf(String(args[0]).toUpperCase()), last = args.length > 1 ? days.indexOf(String(args[1]).toUpperCase()) : first;
  return first <= last ? current >= first && current <= last : current >= first || current <= last;
}
function timeRange() {
  var args = Array.prototype.slice.call(arguments), gmt = String(args[args.length - 1]).toUpperCase() === 'GMT';
  if (gmt) args.pop();
  var now = new Date(), current = (gmt ? now.getUTCHours() : now.getHours()) * 3600 + (gmt ? now.getUTCMinutes() : now.getMinutes()) * 60 + (gmt ? now.getUTCSeconds() : now.getSeconds());
  var start, end;
  if (args.length === 1) { start = Number(args[0]) * 3600; end = start + 3599; }
  else if (args.length === 2) { start = Number(args[0]) * 3600; end = Number(args[1]) * 3600 + 3599; }
  else if (args.length === 4) { start = Number(args[0]) * 3600 + Number(args[1]) * 60; end = Number(args[2]) * 3600 + Number(args[3]) * 60 + 59; }
  else { start = Number(args[0]) * 3600 + Number(args[1]) * 60 + Number(args[2]); end = Number(args[3]) * 3600 + Number(args[4]) * 60 + Number(args[5]); }
  return start <= end ? current >= start && current <= end : current >= start || current <= end;
}
function dateRange() {
  var args = Array.prototype.slice.call(arguments), gmt = String(args[args.length - 1]).toUpperCase() === 'GMT';
  if (gmt) args.pop();
  var months = {JAN:0,FEB:1,MAR:2,APR:3,MAY:4,JUN:5,JUL:6,AUG:7,SEP:8,OCT:9,NOV:10,DEC:11};
  var now = new Date(), year = gmt ? now.getUTCFullYear() : now.getFullYear(), month = gmt ? now.getUTCMonth() : now.getMonth(), day = gmt ? now.getUTCDate() : now.getDate();
  function mon(v) { return months[String(v).toUpperCase()]; }
  if (args.length === 1) { var m = mon(args[0]); if (m !== undefined) return month === m; var n = Number(args[0]); return n > 31 ? year === n : day === n; }
  if (args.length === 2) { var m1 = mon(args[0]), m2 = mon(args[1]); if (m1 !== undefined && m2 !== undefined) return m1 <= m2 ? month >= m1 && month <= m2 : month >= m1 || month <= m2; var a = Number(args[0]), b = Number(args[1]); var value = a > 31 || b > 31 ? year : day; return a <= b ? value >= a && value <= b : value >= a || value <= b; }
  var current = Date.UTC(year, month, day), start, end;
  if (args.length === 4 && mon(args[1]) !== undefined) { start = Date.UTC(year, mon(args[1]), Number(args[0])); end = Date.UTC(year, mon(args[3]), Number(args[2])); }
  else if (args.length === 4) { start = Date.UTC(Number(args[1]), mon(args[0]), 1); end = Date.UTC(Number(args[3]), mon(args[2]) + 1, 0); }
  else { start = Date.UTC(Number(args[2]), mon(args[1]), Number(args[0])); end = Date.UTC(Number(args[5]), mon(args[4]), Number(args[3])); }
  return start <= end ? current >= start && current <= end : current >= start || current <= end;
}
`
