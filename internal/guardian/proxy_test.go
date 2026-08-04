package guardian

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
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
		{name: "socks rejected", input: "socks5://127.0.0.1:1080", wantErr: true},
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
