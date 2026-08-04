//go:build darwin

package guardian

import (
	"bufio"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type macManager struct{ cfg Config }

func newPlatformManager(cfg Config) platformManager { return &macManager{cfg: cfg} }
func (manager *macManager) TargetName() string      { return "Codex in ChatGPT desktop app" }

func (manager *macManager) resolveExecutable() string {
	userHome, _ := os.UserHomeDir()
	for _, configured := range manager.cfg.MacApplicationPaths {
		candidate := configured
		if strings.HasPrefix(candidate, "~/") {
			candidate = filepath.Join(userHome, strings.TrimPrefix(candidate, "~/"))
		}
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return filepath.Clean(candidate)
		}
	}
	return ""
}

type processInfo struct {
	PID, PPID int
	Command   string
}

func macProcesses() []processInfo {
	output, err := exec.Command("ps", "-axo", "pid=,ppid=,command=").Output()
	if err != nil {
		return nil
	}
	result := []processInfo{}
	scanner := bufio.NewScanner(strings.NewReader(string(output)))
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 3 {
			continue
		}
		pid, firstErr := strconv.Atoi(fields[0])
		ppid, secondErr := strconv.Atoi(fields[1])
		if firstErr != nil || secondErr != nil {
			continue
		}
		result = append(result, processInfo{PID: pid, PPID: ppid, Command: strings.Join(fields[2:], " ")})
	}
	return result
}

func (manager *macManager) Observe(proxyURI string) AppObservation {
	executable := manager.resolveExecutable()
	observation := AppObservation{Available: executable != "", Executable: executable}
	if executable == "" {
		return observation
	}
	processes := macProcesses()
	for _, process := range processes {
		if strings.Contains(process.Command, " --type=") {
			continue
		}
		if process.Command == executable || strings.HasPrefix(process.Command, executable+" ") {
			observation.Running = true
			observation.RootPID = process.PID
			observation.LaunchConfigured = containsProxyArgument(process.Command, proxyURI)
			break
		}
	}
	if observation.Running && proxyURI != "" {
		observation.TrafficObserved = macTrafficObserved(processes, observation.RootPID, proxyURI)
	}
	return observation
}

func containsProxyArgument(command, proxyURI string) bool {
	return strings.Contains(command, "--proxy-server="+proxyURI)
}

func macTrafficObserved(processes []processInfo, rootPID int, proxyURI string) bool {
	parsed, err := url.Parse(proxyURI)
	if err != nil {
		return false
	}
	pids := map[int]bool{rootPID: true}
	changed := true
	for changed {
		changed = false
		for _, process := range processes {
			if pids[process.PPID] && !pids[process.PID] {
				pids[process.PID] = true
				changed = true
			}
		}
	}
	pidParts := make([]string, 0, len(pids))
	for pid := range pids {
		pidParts = append(pidParts, strconv.Itoa(pid))
	}
	output, _ := exec.Command("lsof", "-nP", "-a", "-p", strings.Join(pidParts, ","), "-iTCP@"+parsed.Host, "-sTCP:ESTABLISHED").CombinedOutput()
	return strings.Contains(string(output), "ESTABLISHED")
}

func (manager *macManager) Launch(proxyURI string, arguments []string) error {
	executable := manager.resolveExecutable()
	if executable == "" {
		return fmt.Errorf("ChatGPT.app was not found; install it or set MacApplicationPaths")
	}
	launchArguments := append([]string{"--proxy-server=" + proxyURI}, arguments...)
	command := exec.Command(executable, launchArguments...)
	command.Env = proxyEnvironment(proxyURI, manager.cfg.NoProxy)
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	nullFile, err := os.OpenFile(os.DevNull, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	defer nullFile.Close()
	command.Stdin, command.Stdout, command.Stderr = nullFile, nullFile, nullFile
	return command.Start()
}

func (manager *macManager) Restart(proxyURI string, cfg Config) error {
	observation := manager.Observe(proxyURI)
	if observation.Running {
		applicationName := "ChatGPT"
		if strings.Contains(observation.Executable, "/Codex.app/") {
			applicationName = "Codex"
		}
		_ = exec.Command("osascript", "-e", fmt.Sprintf("tell application %q to quit", applicationName)).Run()
		deadline := time.Now().Add(time.Duration(cfg.GracefulCloseSeconds) * time.Second)
		for time.Now().Before(deadline) {
			if !manager.Observe(proxyURI).Running {
				break
			}
			time.Sleep(250 * time.Millisecond)
		}
		if current := manager.Observe(proxyURI); current.Running && current.RootPID == observation.RootPID {
			_ = syscall.Kill(observation.RootPID, syscall.SIGTERM)
		}
	}
	return manager.Launch(proxyURI, nil)
}

var macProxyLine = regexp.MustCompile(`^\s*(HTTP|HTTPS)(Enable|Proxy|Port)\s*:\s*(.+?)\s*$`)

func platformSystemProxyCandidates(Config) []Candidate {
	output, err := exec.Command("scutil", "--proxy").Output()
	if err != nil {
		return nil
	}
	values := map[string]string{}
	for _, line := range strings.Split(string(output), "\n") {
		match := macProxyLine.FindStringSubmatch(line)
		if len(match) == 4 {
			values[match[1]+match[2]] = match[3]
		}
	}
	result := []Candidate{}
	for _, scheme := range []string{"HTTPS", "HTTP"} {
		if values[scheme+"Enable"] == "1" && values[scheme+"Proxy"] != "" && values[scheme+"Port"] != "" {
			result = append(result, Candidate{URI: "http://" + values[scheme+"Proxy"] + ":" + values[scheme+"Port"], Source: "system:macos-" + strings.ToLower(scheme), Score: 300})
		}
	}
	return result
}

var macListenerPattern = regexp.MustCompile(`(?i)^([^\s]+)\s+\d+.*TCP\s+(127\.0\.0\.1|\[::1\]|::1):(\d+)\s+\(LISTEN\)`)

func platformListenerCandidates(cfg Config) []Candidate {
	output, err := exec.Command("lsof", "-nP", "-iTCP", "-sTCP:LISTEN").CombinedOutput()
	if err != nil {
		return nil
	}
	result := []Candidate{}
	for _, line := range strings.Split(string(output), "\n") {
		match := macListenerPattern.FindStringSubmatch(line)
		if len(match) != 4 || !preferredProcess(match[1], cfg.PreferredProxyProcesses) {
			continue
		}
		host := strings.Trim(match[2], "[]")
		result = append(result, Candidate{URI: fmt.Sprintf("http://%s:%s", host, match[3]), Source: "process:" + strings.ToLower(match[1]), Score: 200})
	}
	return result
}
