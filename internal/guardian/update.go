package guardian

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

const releaseRepository = "CH-ZHOU-0512/codex-proxy-guardian"

var errUpdateInstalled = errors.New("update installed")

type releaseAsset struct {
	Name string `json:"name"`
	URL  string `json:"browser_download_url"`
}

type githubRelease struct {
	TagName    string         `json:"tag_name"`
	Draft      bool           `json:"draft"`
	Prerelease bool           `json:"prerelease"`
	Assets     []releaseAsset `json:"assets"`
}

type installMarker struct {
	ProductID  string `json:"productId"`
	BinaryPath string `json:"binaryPath"`
}

func RegisterInstall(binaryPath string) error {
	absolute, err := filepath.Abs(binaryPath)
	if err != nil {
		return err
	}
	info, err := os.Stat(absolute)
	if err != nil || info.IsDir() {
		return fmt.Errorf("installed binary does not exist: %s", absolute)
	}
	root, err := dataRoot()
	if err != nil {
		return err
	}
	return writeJSONAtomic(filepath.Join(root, "install.json"), installMarker{ProductID: "CodexProxyGuardian", BinaryPath: filepath.Clean(absolute)}, 0o600)
}

func UnregisterInstall() error {
	root, err := dataRoot()
	if err != nil {
		return err
	}
	err = os.Remove(filepath.Join(root, "install.json"))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

func CheckForUpdate(install bool) (string, error) {
	if Version == "" || Version == "dev" {
		return "development build; update skipped", nil
	}
	cfg, err := LoadConfig()
	if err != nil {
		return "", err
	}
	client := releaseHTTPClient(cfg)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	releases, err := fetchReleases(ctx, client)
	if err != nil {
		return "", err
	}
	selected := selectRelease(releases, cfg.UpdateChannel)
	if selected == nil || compareVersion(selected.TagName, Version) <= 0 {
		return "already current at v" + Version, nil
	}
	targetVersion := strings.TrimPrefix(selected.TagName, "v")
	assetName := fmt.Sprintf("CodexProxyGuardian-%s-%s-%s.tar.gz", targetVersion, runtime.GOOS, runtime.GOARCH)
	archiveAsset, checksumAsset := findAsset(selected.Assets, assetName), findAsset(selected.Assets, assetName+".sha256")
	if archiveAsset == nil || checksumAsset == nil {
		return "", fmt.Errorf("release %s does not contain %s and its checksum", selected.TagName, assetName)
	}
	if !install {
		return fmt.Sprintf("update available: %s (%s)", selected.TagName, assetName), nil
	}
	marker, err := verifiedInstallMarker()
	if err != nil {
		return "", err
	}
	temporaryRoot, err := os.MkdirTemp("", "CodexProxyGuardian-update-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(temporaryRoot)
	archivePath := filepath.Join(temporaryRoot, assetName)
	checksumPath := archivePath + ".sha256"
	if err := downloadFile(ctx, client, archiveAsset.URL, archivePath, 64*1024*1024); err != nil {
		return "", err
	}
	if err := downloadFile(ctx, client, checksumAsset.URL, checksumPath, 1024*1024); err != nil {
		return "", err
	}
	declared, err := declaredChecksum(checksumPath)
	if err != nil {
		return "", err
	}
	actual, err := fileSHA256(archivePath)
	if err != nil {
		return "", err
	}
	if !strings.EqualFold(declared, actual) {
		return "", errors.New("release archive checksum mismatch")
	}
	extractRoot := filepath.Join(temporaryRoot, "extract")
	if err := extractReleaseArchive(archivePath, extractRoot); err != nil {
		return "", err
	}
	stagedBinary := filepath.Join(extractRoot, "CodexProxyGuardian", "bin", "codex-proxy-guardian")
	stagedVersion, err := os.ReadFile(filepath.Join(extractRoot, "CodexProxyGuardian", "VERSION"))
	if err != nil || strings.TrimSpace(string(stagedVersion)) != targetVersion {
		return "", errors.New("staged VERSION does not match the release tag")
	}
	if err := replaceInstalledBinary(marker.BinaryPath, stagedBinary); err != nil {
		return "", err
	}
	return "updated to " + selected.TagName, nil
}

func releaseHTTPClient(cfg Config) *http.Client {
	transport := &http.Transport{Proxy: http.ProxyFromEnvironment, TLSHandshakeTimeout: 10 * time.Second, ResponseHeaderTimeout: 20 * time.Second}
	if status, err := ReadStatus(); err == nil && status.ActiveProxyValid {
		if proxyURL, parseErr := url.Parse(status.ActiveProxy); parseErr == nil {
			transport.Proxy = http.ProxyURL(proxyURL)
		}
	}
	return &http.Client{Transport: transport, Timeout: 60 * time.Second}
}

func fetchReleases(ctx context.Context, client *http.Client) ([]githubRelease, error) {
	request, _ := http.NewRequestWithContext(ctx, http.MethodGet, "https://api.github.com/repos/"+releaseRepository+"/releases?per_page=20", nil)
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("User-Agent", "CodexProxyGuardian/"+Version)
	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GitHub Releases API returned HTTP %d", response.StatusCode)
	}
	var releases []githubRelease
	if err := json.NewDecoder(io.LimitReader(response.Body, 4*1024*1024)).Decode(&releases); err != nil {
		return nil, err
	}
	return releases, nil
}

func selectRelease(releases []githubRelease, channel string) *githubRelease {
	var selected *githubRelease
	for index := range releases {
		candidate := &releases[index]
		if candidate.Draft || (strings.EqualFold(channel, "Stable") && candidate.Prerelease) || !isSemanticVersion(candidate.TagName) {
			continue
		}
		if selected == nil || compareVersion(candidate.TagName, selected.TagName) > 0 {
			selected = candidate
		}
	}
	return selected
}

func isSemanticVersion(value string) bool {
	_, _, ok := parseSemanticVersion(value)
	return ok
}

func compareVersion(left, right string) int {
	leftCore, leftPre, leftOK := parseSemanticVersion(left)
	rightCore, rightPre, rightOK := parseSemanticVersion(right)
	if !leftOK || !rightOK {
		return strings.Compare(left, right)
	}
	for index := 0; index < 3; index++ {
		if leftCore[index] < rightCore[index] {
			return -1
		}
		if leftCore[index] > rightCore[index] {
			return 1
		}
	}
	if len(leftPre) == 0 && len(rightPre) == 0 {
		return 0
	}
	if len(leftPre) == 0 {
		return 1
	}
	if len(rightPre) == 0 {
		return -1
	}
	for index := 0; index < len(leftPre) && index < len(rightPre); index++ {
		leftNumber, leftNumeric := numericIdentifier(leftPre[index])
		rightNumber, rightNumeric := numericIdentifier(rightPre[index])
		switch {
		case leftNumeric && rightNumeric && leftNumber < rightNumber:
			return -1
		case leftNumeric && rightNumeric && leftNumber > rightNumber:
			return 1
		case leftNumeric && !rightNumeric:
			return -1
		case !leftNumeric && rightNumeric:
			return 1
		case leftPre[index] < rightPre[index]:
			return -1
		case leftPre[index] > rightPre[index]:
			return 1
		}
	}
	if len(leftPre) < len(rightPre) {
		return -1
	}
	if len(leftPre) > len(rightPre) {
		return 1
	}
	return 0
}

func parseSemanticVersion(value string) ([3]int, []string, bool) {
	result := [3]int{}
	value = strings.TrimPrefix(strings.TrimSpace(value), "v")
	value = strings.SplitN(value, "+", 2)[0]
	parts := strings.SplitN(value, "-", 2)
	numbers := strings.Split(parts[0], ".")
	if len(numbers) != 3 {
		return result, nil, false
	}
	for index, number := range numbers {
		if number == "" || (len(number) > 1 && number[0] == '0') {
			return result, nil, false
		}
		parsed, err := strconv.Atoi(number)
		if err != nil || parsed < 0 {
			return result, nil, false
		}
		result[index] = parsed
	}
	if len(parts) == 1 {
		return result, nil, true
	}
	if parts[1] == "" {
		return result, nil, false
	}
	identifiers := strings.Split(parts[1], ".")
	for _, identifier := range identifiers {
		if identifier == "" {
			return result, nil, false
		}
		for _, character := range identifier {
			if !(character == '-' || character >= '0' && character <= '9' || character >= 'A' && character <= 'Z' || character >= 'a' && character <= 'z') {
				return result, nil, false
			}
		}
		if _, numeric := numericIdentifier(identifier); numeric && len(identifier) > 1 && identifier[0] == '0' {
			return result, nil, false
		}
	}
	return result, identifiers, true
}

func numericIdentifier(value string) (int, bool) {
	if value == "" {
		return 0, false
	}
	for _, character := range value {
		if character < '0' || character > '9' {
			return 0, false
		}
	}
	parsed, err := strconv.Atoi(value)
	return parsed, err == nil
}

func findAsset(assets []releaseAsset, name string) *releaseAsset {
	for index := range assets {
		if assets[index].Name == name {
			return &assets[index]
		}
	}
	return nil
}

func downloadFile(ctx context.Context, client *http.Client, sourceURL, destination string, maximum int64) error {
	request, _ := http.NewRequestWithContext(ctx, http.MethodGet, sourceURL, nil)
	request.Header.Set("User-Agent", "CodexProxyGuardian/"+Version)
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK || response.ContentLength > maximum {
		return fmt.Errorf("release download rejected with HTTP %d or excessive size", response.StatusCode)
	}
	file, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	written, copyErr := io.Copy(file, io.LimitReader(response.Body, maximum+1))
	closeErr := file.Close()
	if copyErr != nil {
		return copyErr
	}
	if closeErr != nil {
		return closeErr
	}
	if written > maximum {
		return errors.New("release download exceeds the size limit")
	}
	return nil
}

func declaredChecksum(path string) (string, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	fields := strings.Fields(string(content))
	if len(fields) == 0 || len(fields[0]) != 64 {
		return "", errors.New("release checksum file is invalid")
	}
	if _, err := hex.DecodeString(fields[0]); err != nil {
		return "", errors.New("release checksum is not hexadecimal")
	}
	return strings.ToLower(fields[0]), nil
}

func fileSHA256(path string) (string, error) {
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

func extractReleaseArchive(archivePath, destination string) error {
	file, err := os.Open(archivePath)
	if err != nil {
		return err
	}
	defer file.Close()
	gzipReader, err := gzip.NewReader(file)
	if err != nil {
		return err
	}
	defer gzipReader.Close()
	if err := os.MkdirAll(destination, 0o700); err != nil {
		return err
	}
	prefix := filepath.Clean(destination) + string(os.PathSeparator)
	reader := tar.NewReader(gzipReader)
	entries, total := 0, int64(0)
	for {
		header, nextErr := reader.Next()
		if errors.Is(nextErr, io.EOF) {
			break
		}
		if nextErr != nil {
			return nextErr
		}
		entries++
		total += header.Size
		if entries > 4096 || header.Size < 0 || header.Size > 32*1024*1024 || total > 128*1024*1024 {
			return errors.New("release archive exceeds safe extraction limits")
		}
		target := filepath.Join(destination, filepath.FromSlash(header.Name))
		resolved := filepath.Clean(target)
		if !strings.HasPrefix(resolved, prefix) {
			return errors.New("release archive contains an unsafe path")
		}
		switch header.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(resolved, 0o755); err != nil {
				return err
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(resolved), 0o755); err != nil {
				return err
			}
			output, err := os.OpenFile(resolved, os.O_CREATE|os.O_EXCL|os.O_WRONLY, os.FileMode(header.Mode)&0o755)
			if err != nil {
				return err
			}
			written, copyErr := io.Copy(output, io.LimitReader(reader, header.Size+1))
			closeErr := output.Close()
			if copyErr != nil || closeErr != nil || written != header.Size {
				return errors.New("release archive entry could not be extracted exactly")
			}
		default:
			return errors.New("release archive contains an unsupported entry type")
		}
	}
	return nil
}

func verifiedInstallMarker() (installMarker, error) {
	root, err := dataRoot()
	if err != nil {
		return installMarker{}, err
	}
	var marker installMarker
	if err := readJSON(filepath.Join(root, "install.json"), &marker); err != nil {
		return marker, errors.New("automatic update requires an installation marker; rerun install.sh")
	}
	if marker.ProductID != "CodexProxyGuardian" || !filepath.IsAbs(marker.BinaryPath) {
		return marker, errors.New("installation marker is invalid")
	}
	running, _ := os.Executable()
	running, _ = filepath.EvalSymlinks(running)
	marked, _ := filepath.EvalSymlinks(marker.BinaryPath)
	if filepath.Clean(running) != filepath.Clean(marked) {
		return marker, errors.New("installation marker does not match the running binary")
	}
	return marker, nil
}

func replaceInstalledBinary(destination, staged string) error {
	content, err := os.ReadFile(staged)
	if err != nil {
		return err
	}
	temporary := destination + ".new"
	backup := destination + ".previous"
	_ = os.Remove(temporary)
	if err := os.WriteFile(temporary, content, 0o755); err != nil {
		return err
	}
	if file, err := os.OpenFile(temporary, os.O_RDONLY, 0); err == nil {
		_ = file.Sync()
		_ = file.Close()
	}
	_ = os.Remove(backup)
	if err := os.Rename(destination, backup); err != nil {
		return err
	}
	if err := os.Rename(temporary, destination); err != nil {
		_ = os.Rename(backup, destination)
		return err
	}
	return nil
}
