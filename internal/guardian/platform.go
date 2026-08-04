package guardian

import "time"

type AppObservation struct {
	Available        bool
	Running          bool
	RootPID          int
	LaunchConfigured bool
	TrafficObserved  bool
	Executable       string
}

type platformManager interface {
	TargetName() string
	Observe(proxyURI string) AppObservation
	Launch(proxyURI string, arguments []string) error
	Restart(proxyURI string, cfg Config) error
}

type validationCacheEntry struct {
	Result Validation
	At     time.Time
}
