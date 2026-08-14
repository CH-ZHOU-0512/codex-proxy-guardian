package guardian

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type persistentState struct {
	ActiveProxy         string      `json:"activeProxy,omitempty"`
	ActiveSource        string      `json:"activeSource,omitempty"`
	RestartHistory      []time.Time `json:"restartHistory,omitempty"`
	CircuitBreakerUntil *time.Time  `json:"circuitBreakerUntil,omitempty"`
	LastNotifiedVersion string      `json:"lastNotifiedVersion,omitempty"`
}

type daemonRuntime struct {
	cfg             Config
	logger          *Logger
	manager         platformManager
	persistent      persistentState
	validationCache map[string]validationCacheEntry
	pendingProxy    string
	pendingSource   string
	pendingSince    time.Time
	pendingSamples  int
	externalPID     int
	externalSeenAt  time.Time
	lastRestart     time.Time
	lastUpdateCheck time.Time
}

func RunDaemon() error {
	if runtime.GOOS != "darwin" && runtime.GOOS != "linux" {
		return errors.New("the cross-platform guardian daemon supports macOS and Linux")
	}
	lock, err := acquireInstanceLock()
	if err != nil {
		return fmt.Errorf("another guardian instance is already running: %w", err)
	}
	defer lock.Close()
	if err := writeDaemonPID(); err != nil {
		return err
	}
	defer removeOwnedDaemonPID()
	cfg, err := LoadConfig()
	if err != nil {
		return err
	}
	logger, err := NewLogger(cfg)
	if err != nil {
		return err
	}
	runtimeState := &daemonRuntime{cfg: cfg, logger: logger, manager: newPlatformManager(cfg), validationCache: map[string]validationCacheEntry{}}
	runtimeState.loadPersistent()
	logger.Log("INFO", "guardian_start", "Cross-platform guardian started.", map[string]any{"version": Version, "platform": runtime.GOOS, "target": runtimeState.manager.TargetName()})
	runtimeState.notifyUpdateDetectedAtStartup()

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	for {
		if err := runtimeState.tick(ctx); errors.Is(err, errUpdateInstalled) {
			logger.Log("INFO", "guardian_restart_after_update", "Guardian is replacing itself with the updated binary.", nil)
			if restartErr := restartGuardianDaemon(); restartErr != nil {
				logger.Log("ERROR", "guardian_restart_after_update_failed", "The updated binary is installed but could not be started immediately.", map[string]any{"error_class": classifyError(restartErr)})
			}
		} else if err != nil {
			logger.Log("ERROR", "guardian_tick_failed", "Guardian iteration failed.", map[string]any{"error_class": classifyError(err)})
		}
		select {
		case <-ctx.Done():
			logger.Log("INFO", "guardian_stop", "Guardian stopped.", nil)
			return nil
		case <-time.After(time.Duration(runtimeState.cfg.PollSeconds) * time.Second):
		}
	}
}

func daemonPIDPath() (string, error) {
	root, err := dataRoot()
	return filepath.Join(root, "daemon.pid"), err
}

func writeDaemonPID() error {
	path, err := daemonPIDPath()
	if err != nil {
		return err
	}
	return os.WriteFile(path, []byte(strconv.Itoa(os.Getpid())+"\n"), 0o600)
}

func removeOwnedDaemonPID() {
	path, err := daemonPIDPath()
	if err != nil {
		return
	}
	content, readErr := os.ReadFile(path)
	if readErr == nil && strings.TrimSpace(string(content)) == strconv.Itoa(os.Getpid()) {
		_ = os.Remove(path)
	}
}

func (daemon *daemonRuntime) tick(ctx context.Context) error {
	if refreshed, err := LoadConfig(); err == nil {
		daemon.cfg = refreshed
	}
	selected, validation := daemon.selectProxy(ctx)
	previousProxy := daemon.persistent.ActiveProxy
	stateName := "WaitingForProxy"
	if selected.URI != "" && validation.Valid {
		if selected.URI == daemon.persistent.ActiveProxy {
			daemon.pendingProxy, daemon.pendingSamples = "", 0
		} else if selected.URI != daemon.pendingProxy {
			daemon.pendingProxy, daemon.pendingSource = selected.URI, selected.Source
			daemon.pendingSince, daemon.pendingSamples = time.Now(), 1
		} else {
			daemon.pendingSamples++
		}
		if daemon.pendingProxy != "" {
			stateName = "Stabilizing"
			if daemon.pendingSamples >= daemon.cfg.StableSamples && time.Since(daemon.pendingSince) >= time.Duration(daemon.cfg.DebounceSeconds)*time.Second {
				daemon.persistent.ActiveProxy, daemon.persistent.ActiveSource = daemon.pendingProxy, daemon.pendingSource
				daemon.pendingProxy, daemon.pendingSamples = "", 0
				daemon.logger.Log("INFO", "proxy_activated", "A stable validated proxy became active.", map[string]any{"proxy": daemon.persistent.ActiveProxy, "source": daemon.persistent.ActiveSource})
				daemon.savePersistent()
			}
		} else {
			stateName = "Ready"
		}
	}

	observation := daemon.manager.Observe(daemon.persistent.ActiveProxy)
	if runtime.GOOS == "linux" && daemon.persistent.ActiveProxy != "" {
		stateName = "ReadyForCLI"
	}
	if runtime.GOOS == "darwin" && daemon.persistent.ActiveProxy != "" {
		stateName = daemon.manageMacApplication(previousProxy, observation, stateName)
		observation = daemon.manager.Observe(daemon.persistent.ActiveProxy)
	}

	status := Status{
		SchemaVersion: 1, Version: Version, Platform: runtime.GOOS, Target: daemon.manager.TargetName(),
		GuardianState: stateName, Mode: daemon.cfg.Mode, ActiveProxy: daemon.persistent.ActiveProxy,
		ActiveSource: daemon.persistent.ActiveSource, ActiveProxyValid: daemon.persistent.ActiveProxy != "" && selected.URI == daemon.persistent.ActiveProxy && validation.Valid,
		Validation: validation, LaunchConfigured: observation.LaunchConfigured, TrafficObserved: observation.TrafficObserved,
		ApplicationRunning: observation.Running, CircuitBreakerUntil: daemon.persistent.CircuitBreakerUntil,
		RecentRestartCount: len(daemon.recentRestarts()), LastUpdated: time.Now().UTC(), LastErrorClass: validation.LastErrorClass,
	}
	if err := saveStatus(status); err != nil {
		return err
	}

	if daemon.cfg.AutomaticUpdates && (daemon.lastUpdateCheck.IsZero() || time.Since(daemon.lastUpdateCheck) >= 24*time.Hour) {
		daemon.lastUpdateCheck = time.Now()
		if result, err := CheckForUpdate(true); err == nil && strings.HasPrefix(result, "updated ") {
			daemon.logger.Log("INFO", "automatic_update", result, nil)
			installedVersion := strings.TrimPrefix(strings.TrimSpace(strings.TrimPrefix(result, "updated to ")), "v")
			if daemon.cfg.NotifyAfterAutomaticUpdate {
				if notifyErr := notifyAutomaticUpdate(Version, installedVersion); notifyErr != nil {
					daemon.logger.Log("WARN", "automatic_update_notification_failed", "The update completed, but the desktop notification could not be shown.", map[string]any{"installed_version": installedVersion, "error_class": classifyError(notifyErr)})
				} else {
					daemon.persistent.LastNotifiedVersion = installedVersion
					daemon.savePersistent()
					daemon.logger.Log("INFO", "automatic_update_notification_shown", "The automatic update completion notification was shown.", map[string]any{"installed_version": installedVersion})
				}
			}
			return errUpdateInstalled
		}
	}
	return nil
}

func (daemon *daemonRuntime) notifyUpdateDetectedAtStartup() {
	if !daemon.cfg.NotifyAfterAutomaticUpdate {
		return
	}
	previousStatus, err := ReadStatus()
	if err != nil || !shouldNotifyAutomaticUpdate(previousStatus.Version, Version, daemon.persistent.LastNotifiedVersion) {
		return
	}
	if err := notifyAutomaticUpdate(previousStatus.Version, Version); err != nil {
		daemon.logger.Log("WARN", "automatic_update_notification_failed", "An installed update was detected, but the desktop notification could not be shown.", map[string]any{"previous_version": previousStatus.Version, "installed_version": Version, "error_class": classifyError(err)})
		return
	}
	daemon.persistent.LastNotifiedVersion = strings.TrimPrefix(Version, "v")
	daemon.savePersistent()
	daemon.logger.Log("INFO", "automatic_update_notification_shown", "The installed update was announced after Guardian restarted.", map[string]any{"previous_version": previousStatus.Version, "installed_version": Version})
}

func (daemon *daemonRuntime) selectProxy(ctx context.Context) (Candidate, Validation) {
	candidates := DiscoverCandidates(daemon.cfg, daemon.persistent.ActiveProxy)
	last := Validation{TargetCount: len(daemon.cfg.ProxyTestURLs), CheckedAt: time.Now().UTC(), LastErrorClass: "no_candidate"}
	for _, candidate := range candidates {
		cached, exists := daemon.validationCache[candidate.URI]
		if exists && time.Since(cached.At) < time.Duration(daemon.cfg.HTTPValidationIntervalSeconds)*time.Second {
			last = cached.Result
		} else {
			last = ValidateCandidate(ctx, candidate, daemon.cfg)
			daemon.validationCache[candidate.URI] = validationCacheEntry{Result: last, At: time.Now()}
		}
		if last.Valid {
			return candidate, last
		}
	}
	return Candidate{}, last
}

func (daemon *daemonRuntime) manageMacApplication(previousProxy string, observation AppObservation, stateName string) string {
	if !observation.Available {
		return "CodexApplicationUnavailable"
	}
	if !observation.Running {
		daemon.externalPID = 0
		if daemon.cfg.LaunchMacApplicationWhenNotRunning && daemon.allowRestart() {
			if err := daemon.manager.Launch(daemon.persistent.ActiveProxy, nil); err == nil {
				daemon.registerRestart()
				return "Ready"
			}
		}
		return "Ready"
	}
	if previousProxy != "" && previousProxy != daemon.persistent.ActiveProxy {
		return daemon.performRestart("proxy_changed")
	}
	if observation.LaunchConfigured || observation.TrafficObserved {
		daemon.externalPID = 0
		return "Ready"
	}
	if daemon.externalPID != observation.RootPID {
		daemon.externalPID, daemon.externalSeenAt = observation.RootPID, time.Now()
	}
	wait := time.Duration(daemon.cfg.SafeExternalLaunchGraceSeconds) * time.Second
	if daemon.cfg.Mode == "Enforce" {
		wait = time.Duration(daemon.cfg.ExternalLaunchDebounceSeconds) * time.Second
	}
	if daemon.cfg.Mode == "Safe" && !daemon.cfg.SafeRepairExternalCodexLaunches {
		return "CodexNeedsManagedLaunch"
	}
	if time.Since(daemon.externalSeenAt) < wait {
		return "EvaluatingCodexLaunch"
	}
	return daemon.performRestart("missing_proxy_argument")
}

func (daemon *daemonRuntime) performRestart(reason string) string {
	if !daemon.allowRestart() {
		if daemon.persistent.CircuitBreakerUntil != nil && daemon.persistent.CircuitBreakerUntil.After(time.Now()) {
			return "RestartCircuitOpen"
		}
		return "WaitingForRestartBudget"
	}
	if err := daemon.manager.Restart(daemon.persistent.ActiveProxy, daemon.cfg); err != nil {
		daemon.logger.Log("ERROR", "codex_restart_failed", "Could not restart the macOS Codex application.", map[string]any{"reason": reason, "error_class": classifyError(err)})
		return "RecoveryPending"
	}
	daemon.registerRestart()
	daemon.externalPID = 0
	daemon.logger.Log("INFO", "codex_restarted", "Restarted the macOS Codex application with the validated proxy.", map[string]any{"reason": reason})
	return "Ready"
}

func (daemon *daemonRuntime) recentRestarts() []time.Time {
	cutoff := time.Now().Add(-time.Duration(daemon.cfg.RestartLimitWindowMinutes) * time.Minute)
	result := []time.Time{}
	for _, item := range daemon.persistent.RestartHistory {
		if item.After(cutoff) && !item.After(time.Now().Add(time.Minute)) {
			result = append(result, item)
		}
	}
	daemon.persistent.RestartHistory = result
	return result
}

func (daemon *daemonRuntime) allowRestart() bool {
	now := time.Now()
	if daemon.persistent.CircuitBreakerUntil != nil && daemon.persistent.CircuitBreakerUntil.After(now) {
		return false
	}
	if !daemon.lastRestart.IsZero() && time.Since(daemon.lastRestart) < time.Duration(daemon.cfg.RestartCooldownSeconds)*time.Second {
		return false
	}
	if len(daemon.recentRestarts()) >= daemon.cfg.RestartLimitCount {
		until := now.Add(time.Duration(daemon.cfg.CircuitBreakerMinutes) * time.Minute)
		daemon.persistent.CircuitBreakerUntil = &until
		daemon.savePersistent()
		return false
	}
	return true
}

func (daemon *daemonRuntime) registerRestart() {
	now := time.Now().UTC()
	daemon.lastRestart = now
	daemon.persistent.RestartHistory = append(daemon.recentRestarts(), now)
	daemon.persistent.CircuitBreakerUntil = nil
	daemon.savePersistent()
}

func persistentPath() (string, error) {
	root, err := dataRoot()
	return filepath.Join(root, "state.json"), err
}

func (daemon *daemonRuntime) loadPersistent() {
	path, err := persistentPath()
	if err != nil {
		return
	}
	_ = readJSON(path, &daemon.persistent)
	if history := daemon.recentRestarts(); len(history) > 0 {
		daemon.lastRestart = history[len(history)-1]
	}
}

func (daemon *daemonRuntime) savePersistent() {
	path, err := persistentPath()
	if err == nil {
		_ = writeJSONAtomic(path, daemon.persistent, 0o600)
	}
}

func readJSON(path string, target any) error {
	content, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(content, target)
}

func classifyError(err error) string {
	if err == nil {
		return ""
	}
	text := strings.ToLower(err.Error())
	for _, class := range []string{"timeout", "permission", "not found", "connection", "checksum", "version"} {
		if strings.Contains(text, class) {
			return strings.ReplaceAll(class, " ", "_")
		}
	}
	return "operation_failed"
}

func LaunchCodex(arguments []string) error {
	cfg, err := LoadConfig()
	if err != nil {
		return err
	}
	proxyURI := ""
	if status, statusErr := ReadStatus(); statusErr == nil && status.ActiveProxyValid && time.Since(status.LastUpdated) < 2*time.Minute {
		proxyURI = status.ActiveProxy
	}
	if proxyURI == "" {
		ctx, cancel := context.WithTimeout(context.Background(), time.Duration(cfg.HTTPTimeoutSeconds*len(cfg.ProxyTestURLs)+5)*time.Second)
		defer cancel()
		for _, candidate := range DiscoverCandidates(cfg, "") {
			if validation := ValidateCandidate(ctx, candidate, cfg); validation.Valid {
				proxyURI = candidate.URI
				break
			}
		}
	}
	if proxyURI == "" {
		return errors.New("no proxy passed the configured HTTPS validation quorum")
	}
	return newPlatformManager(cfg).Launch(proxyURI, arguments)
}
