package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/CH-ZHOU-0512/codex-proxy-guardian/internal/guardian"
)

func main() {
	arguments := os.Args[1:]
	if strings.EqualFold(filepath.Base(os.Args[0]), "codex-guard") {
		arguments = append([]string{"launch"}, arguments...)
	}
	if err := run(arguments); err != nil {
		fmt.Fprintln(os.Stderr, "codex-proxy-guardian:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	command := "help"
	if len(args) > 0 {
		command, args = strings.ToLower(args[0]), args[1:]
	}

	switch command {
	case "daemon":
		return guardian.RunDaemon()
	case "launch", "run":
		return guardian.LaunchCodex(args)
	case "status":
		flags := flag.NewFlagSet("status", flag.ContinueOnError)
		asJSON := flags.Bool("json", false, "print JSON")
		if err := flags.Parse(args); err != nil {
			return err
		}
		status, err := guardian.ReadStatus()
		if err != nil {
			return err
		}
		if *asJSON {
			encoded, _ := json.MarshalIndent(status, "", "  ")
			fmt.Println(string(encoded))
			return nil
		}
		guardian.PrintStatus(os.Stdout, status)
		return nil
	case "doctor":
		report, err := guardian.Doctor()
		if err != nil {
			return err
		}
		encoded, _ := json.MarshalIndent(report, "", "  ")
		fmt.Println(string(encoded))
		return nil
	case "mode":
		if len(args) != 1 {
			return errors.New("usage: codex-proxy-guardian mode auto|strict")
		}
		return guardian.SetMode(args[0])
	case "update":
		install := len(args) > 0 && args[0] == "--install"
		result, err := guardian.CheckForUpdate(install)
		if err != nil {
			return err
		}
		fmt.Println(result)
		return nil
	case "register-install":
		if len(args) != 1 {
			return errors.New("usage: register-install ABSOLUTE_BINARY_PATH")
		}
		return guardian.RegisterInstall(args[0])
	case "unregister-install":
		return guardian.UnregisterInstall()
	case "service":
		if len(args) != 1 || (args[0] != "install" && args[0] != "uninstall") {
			return errors.New("usage: codex-proxy-guardian service install|uninstall")
		}
		if args[0] == "install" {
			return guardian.InstallUserService()
		}
		return guardian.UninstallUserService()
	case "version", "--version", "-v":
		fmt.Println(guardian.Version)
		return nil
	case "help", "--help", "-h":
		printHelp()
		return nil
	default:
		return fmt.Errorf("unknown command %q; run with help", command)
	}
}

func printHelp() {
	fmt.Println(`Codex Proxy Guardian

Usage:
  codex-proxy-guardian daemon           run the background guardian
  codex-proxy-guardian launch [args]    launch Codex with the validated proxy
  codex-proxy-guardian status [--json]  show current evidence and state
  codex-proxy-guardian doctor           print a share-safe diagnostic report
  codex-proxy-guardian mode auto|strict switch repair policy
  codex-proxy-guardian update [--install]
  codex-proxy-guardian version

On Linux, codex-guard is an alias for the launch command.`)
}
