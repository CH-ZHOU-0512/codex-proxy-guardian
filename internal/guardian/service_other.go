//go:build !darwin && !linux

package guardian

import "fmt"

func platformInstallUserService(string) error { return fmt.Errorf("unsupported platform") }
func platformUninstallUserService() error     { return fmt.Errorf("unsupported platform") }
