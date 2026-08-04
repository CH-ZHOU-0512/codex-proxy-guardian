package guardian

import (
	"archive/tar"
	"compress/gzip"
	"os"
	"path/filepath"
	"testing"
)

func TestCompareVersionUsesSemanticPrereleaseOrdering(t *testing.T) {
	tests := []struct {
		left, right string
		want        int
	}{
		{"v1.2.0", "1.2.0-rc.9", 1},
		{"1.2.0-alpha.10", "1.2.0-alpha.2", 1},
		{"1.2.0-alpha", "1.2.0-alpha.1", -1},
		{"1.2.0-1", "1.2.0-alpha", -1},
		{"1.10.0", "1.9.9", 1},
		{"1.2.0+build.2", "1.2.0+build.1", 0},
	}
	for _, test := range tests {
		got := compareVersion(test.left, test.right)
		if got != test.want {
			t.Fatalf("compareVersion(%q, %q) = %d, want %d", test.left, test.right, got, test.want)
		}
	}
}

func TestSelectReleaseHonorsChannel(t *testing.T) {
	releases := []githubRelease{
		{TagName: "v1.2.0-alpha.10", Prerelease: true},
		{TagName: "v1.1.0"},
		{TagName: "v1.2.0-alpha.2", Prerelease: true},
		{TagName: "not-a-version"},
		{TagName: "v9.0.0", Draft: true},
	}
	if got := selectRelease(releases, "Stable"); got == nil || got.TagName != "v1.1.0" {
		t.Fatalf("stable selection = %#v", got)
	}
	if got := selectRelease(releases, "Prerelease"); got == nil || got.TagName != "v1.2.0-alpha.10" {
		t.Fatalf("prerelease selection = %#v", got)
	}
}

func TestExtractReleaseArchiveRejectsTraversal(t *testing.T) {
	archive := filepath.Join(t.TempDir(), "unsafe.tar.gz")
	writeTestArchive(t, archive, "../escape", "bad")
	if err := extractReleaseArchive(archive, filepath.Join(t.TempDir(), "out")); err == nil {
		t.Fatal("expected traversal archive to be rejected")
	}
}

func TestExtractReleaseArchiveExtractsRegularFile(t *testing.T) {
	archive := filepath.Join(t.TempDir(), "valid.tar.gz")
	writeTestArchive(t, archive, "CodexProxyGuardian/VERSION", "1.2.0\n")
	destination := filepath.Join(t.TempDir(), "out")
	if err := extractReleaseArchive(archive, destination); err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(filepath.Join(destination, "CodexProxyGuardian", "VERSION"))
	if err != nil || string(content) != "1.2.0\n" {
		t.Fatalf("unexpected extracted content %q, %v", content, err)
	}
}

func writeTestArchive(t *testing.T, path, name, content string) {
	t.Helper()
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	gzipWriter := gzip.NewWriter(file)
	tarWriter := tar.NewWriter(gzipWriter)
	if err := tarWriter.WriteHeader(&tar.Header{Name: name, Mode: 0o644, Size: int64(len(content)), Typeflag: tar.TypeReg}); err != nil {
		t.Fatal(err)
	}
	if _, err := tarWriter.Write([]byte(content)); err != nil {
		t.Fatal(err)
	}
	if err := tarWriter.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gzipWriter.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
}
