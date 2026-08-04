package guardian

import (
	"bufio"
	"context"
	"encoding/binary"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestNormalizeProxy(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		allow   bool
		want    string
		wantErr bool
	}{
		{name: "loopback", input: "127.0.0.1:7890", want: "http://127.0.0.1:7890"},
		{name: "localhost", input: "https://LOCALHOST:7891", want: "https://localhost:7891"},
		{name: "remote rejected", input: "http://192.0.2.10:8080", wantErr: true},
		{name: "remote opted in", input: "http://192.0.2.10:8080", allow: true, want: "http://192.0.2.10:8080"},
		{name: "socks5 uses proxy DNS", input: "socks5://127.0.0.1:1080", want: "socks5h://127.0.0.1:1080"},
		{name: "socks alias uses proxy DNS", input: "socks://127.0.0.1:1080", want: "socks5h://127.0.0.1:1080"},
		{name: "socks4 rejected", input: "socks4://127.0.0.1:1080", wantErr: true},
		{name: "credentials rejected", input: "http://user:secret@127.0.0.1:7890", wantErr: true},
		{name: "missing port", input: "http://localhost", wantErr: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := NormalizeProxy(test.input, test.allow)
			if (err != nil) != test.wantErr || got != test.want {
				t.Fatalf("NormalizeProxy() = %q, %v; want %q, error=%v", got, err, test.want, test.wantErr)
			}
		})
	}
}

func TestValidateCandidateUsesSOCKS5Proxy(t *testing.T) {
	targetRequests := 0
	target := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		targetRequests++
		writer.WriteHeader(http.StatusNoContent)
	}))
	defer target.Close()
	proxyAddress, stopProxy := startTestSOCKS5Proxy(t)
	defer stopProxy()
	cfg := DefaultConfig()
	cfg.ProxyTestURLs = []string{target.URL}
	cfg.MinimumSuccessfulProxyTests = 1
	cfg.HTTPTimeoutSeconds = 2
	validation := ValidateCandidate(context.Background(), Candidate{URI: "socks5h://" + proxyAddress}, cfg)
	if !validation.Valid || validation.Successful != 1 || targetRequests != 1 {
		t.Fatalf("unexpected SOCKS5 validation: %#v, targetRequests=%d", validation, targetRequests)
	}
}

func startTestSOCKS5Proxy(t *testing.T) (string, func()) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			client, acceptErr := listener.Accept()
			if acceptErr != nil {
				return
			}
			go serveTestSOCKS5Connection(client)
		}
	}()
	return listener.Addr().String(), func() {
		_ = listener.Close()
		<-done
	}
}

func serveTestSOCKS5Connection(client net.Conn) {
	defer client.Close()
	reader := bufio.NewReader(client)
	header := make([]byte, 2)
	if _, err := io.ReadFull(reader, header); err != nil || header[0] != 5 {
		return
	}
	methods := make([]byte, int(header[1]))
	if _, err := io.ReadFull(reader, methods); err != nil {
		return
	}
	if _, err := client.Write([]byte{5, 0}); err != nil {
		return
	}
	request := make([]byte, 4)
	if _, err := io.ReadFull(reader, request); err != nil || request[0] != 5 || request[1] != 1 {
		return
	}
	var host string
	switch request[3] {
	case 1:
		address := make([]byte, 4)
		if _, err := io.ReadFull(reader, address); err != nil {
			return
		}
		host = net.IP(address).String()
	case 3:
		length, err := reader.ReadByte()
		if err != nil {
			return
		}
		address := make([]byte, int(length))
		if _, err := io.ReadFull(reader, address); err != nil {
			return
		}
		host = string(address)
	case 4:
		address := make([]byte, 16)
		if _, err := io.ReadFull(reader, address); err != nil {
			return
		}
		host = net.IP(address).String()
	default:
		return
	}
	portBytes := make([]byte, 2)
	if _, err := io.ReadFull(reader, portBytes); err != nil {
		return
	}
	upstream, err := net.Dial("tcp", net.JoinHostPort(host, strconv.Itoa(int(binary.BigEndian.Uint16(portBytes)))))
	if err != nil {
		_, _ = client.Write([]byte{5, 5, 0, 1, 0, 0, 0, 0, 0, 0})
		return
	}
	defer upstream.Close()
	if _, err := client.Write([]byte{5, 0, 0, 1, 0, 0, 0, 0, 0, 0}); err != nil {
		return
	}
	go func() { _, _ = io.Copy(upstream, reader); _ = upstream.Close() }()
	_, _ = io.Copy(client, upstream)
}

func TestDiscoverCandidatesFromExplicitPAC(t *testing.T) {
	pac := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		_, _ = io.WriteString(writer, `function FindProxyForURL(url, host) { return "SOCKS5 127.0.0.1:1080; DIRECT"; }`)
	}))
	defer pac.Close()
	cfg := DefaultConfig()
	cfg.ExplicitPAC = pac.URL
	cfg.ProxyTestURLs = []string{"https://chatgpt.com/"}
	candidates := DiscoverCandidates(cfg, "")
	found := false
	for _, candidate := range candidates {
		if candidate.URI == "socks5h://127.0.0.1:1080" && candidate.Source == "config:explicit-pac:target-1" {
			found = true
		}
	}
	if !found {
		t.Fatalf("PAC SOCKS5 route was not discovered: %#v", candidates)
	}
}

func TestParsePACResultPreservesSupportedFallbackOrder(t *testing.T) {
	got := parsePACResult("PROXY 127.0.0.1:8080; SOCKS5 127.0.0.1:1080; SOCKS4 127.0.0.1:1081; DIRECT")
	want := []string{"http://127.0.0.1:8080", "socks5h://127.0.0.1:1080"}
	if len(got) != len(want) {
		t.Fatalf("parsePACResult() = %#v", got)
	}
	for index := range want {
		if got[index] != want[index] {
			t.Fatalf("parsePACResult()[%d] = %q, want %q", index, got[index], want[index])
		}
	}
}

func TestEvaluatePACUsesTargetAndHelpers(t *testing.T) {
	cfg := DefaultConfig()
	script := `function FindProxyForURL(url, host) {
		if (dnsDomainIs(host, ".openai.com") && shExpMatch(url, "https://*/*")) return "PROXY 127.0.0.1:7890";
		return "DIRECT";
	}`
	routes, err := evaluatePAC(script, "https://api.openai.com/v1/models", cfg)
	if err != nil || len(routes) != 1 || routes[0] != "http://127.0.0.1:7890" {
		t.Fatalf("evaluatePAC() = %#v, %v", routes, err)
	}
}

func TestEvaluatePACInterruptsRunawayScript(t *testing.T) {
	cfg := DefaultConfig()
	cfg.PACExecutionTimeoutMilliseconds = 50
	started := time.Now()
	_, err := evaluatePAC(`function FindProxyForURL(url, host) { while (true) {} }`, "https://chatgpt.com/", cfg)
	if err == nil {
		t.Fatal("runaway PAC script was not interrupted")
	}
	if time.Since(started) > time.Second {
		t.Fatalf("PAC interruption took too long: %s", time.Since(started))
	}
}

func TestLoadPACDocumentRejectsOversizedSource(t *testing.T) {
	pac := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		_, _ = io.WriteString(writer, strings.Repeat("x", 1025))
	}))
	defer pac.Close()
	cfg := DefaultConfig()
	cfg.PACMaxBytes = 1024
	if _, err := loadPACDocument(pac.URL, cfg); err == nil {
		t.Fatal("oversized PAC document was accepted")
	}
}

func TestNormalizePACURLRejectsCredentials(t *testing.T) {
	if _, err := normalizePACURL("https://user:secret@example.com/proxy.pac"); err == nil {
		t.Fatal("PAC URL credentials were accepted")
	}
	if normalized, err := normalizePACURL((&url.URL{Scheme: "file", Path: "/tmp/test.pac"}).String()); err != nil || normalized == "" {
		t.Fatalf("file PAC URL rejected: %q, %v", normalized, err)
	}
}

func TestDiscoverCandidatesPrefersExplicitProxy(t *testing.T) {
	cfg := DefaultConfig()
	cfg.ExplicitProxy = "127.0.0.1:45678"
	candidates := DiscoverCandidates(cfg, "")
	if len(candidates) == 0 || candidates[0].URI != "http://127.0.0.1:45678" || candidates[0].Source != "config:explicit" {
		t.Fatalf("explicit proxy was not first: %#v", candidates)
	}
}

func TestValidateCandidateUsesProxyAndQuorum(t *testing.T) {
	requests := 0
	proxy := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		requests++
		writer.WriteHeader(http.StatusNoContent)
	}))
	defer proxy.Close()
	cfg := DefaultConfig()
	cfg.ProxyTestURLs = []string{"http://example.invalid/one", "http://example.invalid/two"}
	cfg.MinimumSuccessfulProxyTests = 2
	cfg.HTTPTimeoutSeconds = 2
	validation := ValidateCandidate(context.Background(), Candidate{URI: proxy.URL}, cfg)
	if !validation.Valid || validation.Successful != 2 || requests != 2 {
		t.Fatalf("unexpected validation: %#v, requests=%d", validation, requests)
	}
}
