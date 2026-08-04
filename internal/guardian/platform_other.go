//go:build !darwin && !linux

package guardian

import "fmt"

type unsupportedManager struct{}

func newPlatformManager(Config) platformManager           { return &unsupportedManager{} }
func (*unsupportedManager) TargetName() string            { return "unsupported platform" }
func (*unsupportedManager) Observe(string) AppObservation { return AppObservation{} }
func (*unsupportedManager) Launch(string, []string) error {
	return fmt.Errorf("this binary supports macOS and Linux")
}
func (*unsupportedManager) Restart(string, Config) error {
	return fmt.Errorf("this binary supports macOS and Linux")
}
func platformSystemProxyCandidates(Config) []Candidate { return nil }
func platformListenerCandidates(Config) []Candidate    { return nil }
