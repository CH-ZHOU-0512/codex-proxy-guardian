//go:build ignore

// package-posix.go builds reproducible current-user release bundles for macOS
// and Linux. Run it from the repository root with: go run ./tools/package-posix.go
package main

import (
	"archive/tar"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

type target struct {
	goos   string
	goarch string
}

type archiveEntry struct {
	source string
	name   string
	mode   int64
}

func main() {
	rootFlag := flag.String("root", ".", "repository root")
	outFlag := flag.String("out", "artifacts", "output directory")
	versionFlag := flag.String("version", "", "release version; defaults to VERSION")
	flag.Parse()

	root, err := filepath.Abs(*rootFlag)
	must(err)
	output := *outFlag
	if !filepath.IsAbs(output) {
		output = filepath.Join(root, output)
	}
	must(os.MkdirAll(output, 0o755))
	version := strings.TrimSpace(*versionFlag)
	if version == "" {
		content, readErr := os.ReadFile(filepath.Join(root, "VERSION"))
		must(readErr)
		version = strings.TrimSpace(string(content))
	}
	if version == "" {
		panic("VERSION is empty")
	}

	for _, item := range []target{{"darwin", "amd64"}, {"darwin", "arm64"}, {"linux", "amd64"}, {"linux", "arm64"}} {
		must(packageTarget(root, output, version, item))
	}
}

func packageTarget(root, output, version string, item target) error {
	temporary, err := os.MkdirTemp("", "CodexProxyGuardian-posix-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(temporary)
	binary := filepath.Join(temporary, "codex-proxy-guardian")
	command := exec.Command("go", "build", "-trimpath", "-ldflags", "-s -w -X github.com/CH-ZHOU-0512/codex-proxy-guardian/internal/guardian.Version="+version, "-o", binary, "./cmd/codex-proxy-guardian")
	command.Dir = root
	command.Env = append(filteredEnvironment(os.Environ(), "GOOS", "GOARCH", "CGO_ENABLED"), "GOOS="+item.goos, "GOARCH="+item.goarch, "CGO_ENABLED=0")
	command.Stdout, command.Stderr = os.Stdout, os.Stderr
	if err := command.Run(); err != nil {
		return fmt.Errorf("build %s/%s: %w", item.goos, item.goarch, err)
	}

	name := fmt.Sprintf("CodexProxyGuardian-%s-%s-%s.tar.gz", version, item.goos, item.goarch)
	archivePath := filepath.Join(output, name)
	entries := []archiveEntry{
		{binary, "CodexProxyGuardian/bin/codex-proxy-guardian", 0o755},
		{filepath.Join(root, "platform", "install.sh"), "CodexProxyGuardian/install.sh", 0o755},
		{filepath.Join(root, "platform", "uninstall.sh"), "CodexProxyGuardian/uninstall.sh", 0o755},
		{filepath.Join(root, "platform", "README.md"), "CodexProxyGuardian/README.md", 0o644},
		{filepath.Join(root, "config", "default-posix-config.json"), "CodexProxyGuardian/config/default-posix-config.json", 0o644},
		{filepath.Join(root, "LICENSE"), "CodexProxyGuardian/LICENSE", 0o644},
		{filepath.Join(root, "VERSION"), "CodexProxyGuardian/VERSION", 0o644},
	}
	if err := writeArchive(archivePath, entries); err != nil {
		return err
	}
	digest, err := sha256File(archivePath)
	if err != nil {
		return err
	}
	checksum := digest + "  " + name + "\n"
	if err := os.WriteFile(archivePath+".sha256", []byte(checksum), 0o644); err != nil {
		return err
	}
	fmt.Printf("packaged %s/%s: %s\n", item.goos, item.goarch, archivePath)
	return nil
}

func writeArchive(destination string, entries []archiveEntry) error {
	file, err := os.OpenFile(destination, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	gzipWriter, err := gzip.NewWriterLevel(file, gzip.BestCompression)
	if err != nil {
		file.Close()
		return err
	}
	gzipWriter.Header.ModTime = time.Unix(0, 0)
	gzipWriter.Header.OS = 255
	tarWriter := tar.NewWriter(gzipWriter)
	fixedTime := time.Unix(0, 0)
	for _, entry := range entries {
		info, statErr := os.Stat(entry.source)
		if statErr != nil {
			return closeArchiveWithError(tarWriter, gzipWriter, file, statErr)
		}
		header := &tar.Header{Name: entry.name, Mode: entry.mode, Size: info.Size(), ModTime: fixedTime, AccessTime: fixedTime, ChangeTime: fixedTime, Typeflag: tar.TypeReg, Uid: 0, Gid: 0}
		if err := tarWriter.WriteHeader(header); err != nil {
			return closeArchiveWithError(tarWriter, gzipWriter, file, err)
		}
		source, openErr := os.Open(entry.source)
		if openErr != nil {
			return closeArchiveWithError(tarWriter, gzipWriter, file, openErr)
		}
		_, copyErr := io.Copy(tarWriter, source)
		closeErr := source.Close()
		if copyErr != nil {
			return closeArchiveWithError(tarWriter, gzipWriter, file, copyErr)
		}
		if closeErr != nil {
			return closeArchiveWithError(tarWriter, gzipWriter, file, closeErr)
		}
	}
	if err := tarWriter.Close(); err != nil {
		gzipWriter.Close()
		file.Close()
		return err
	}
	if err := gzipWriter.Close(); err != nil {
		file.Close()
		return err
	}
	return file.Close()
}

func closeArchiveWithError(tarWriter *tar.Writer, gzipWriter *gzip.Writer, file *os.File, original error) error {
	_ = tarWriter.Close()
	_ = gzipWriter.Close()
	_ = file.Close()
	return original
}

func sha256File(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	digest := sha256.New()
	if _, err := io.Copy(digest, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(digest.Sum(nil)), nil
}

func filteredEnvironment(environment []string, names ...string) []string {
	blocked := map[string]bool{}
	for _, name := range names {
		blocked[strings.ToUpper(name)] = true
	}
	result := make([]string, 0, len(environment))
	for _, value := range environment {
		name, _, _ := strings.Cut(value, "=")
		if !blocked[strings.ToUpper(name)] {
			result = append(result, value)
		}
	}
	return result
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}
