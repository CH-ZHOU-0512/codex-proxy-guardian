package guardian

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
)

func InstallUserService() error {
	if runtime.GOOS != "darwin" && runtime.GOOS != "linux" {
		return fmt.Errorf("user service installation supports macOS and Linux")
	}
	binary, err := os.Executable()
	if err != nil {
		return err
	}
	binary, err = filepath.EvalSymlinks(binary)
	if err != nil {
		return err
	}
	return platformInstallUserService(binary)
}

func UninstallUserService() error {
	if runtime.GOOS != "darwin" && runtime.GOOS != "linux" {
		return fmt.Errorf("user service uninstallation supports macOS and Linux")
	}
	return platformUninstallUserService()
}
