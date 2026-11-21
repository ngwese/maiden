package cmd

import (
	"os"
	"os/exec"
	"syscall"

	"github.com/spf13/cobra"
)

var replCmd = &cobra.Command{
	Use:   "repl",
	Short: "norns repl",
	Run: func(cmd *cobra.Command, args []string) {
		ConfigureLogger()
		replRun(args)
	},
}

func init() {
	rootCmd.AddCommand(replCmd)
}

func replRun(args []string) {
	binary, lookErr := exec.LookPath("maiden-repl")
	if lookErr != nil {
		logger.Fatal(lookErr)
	}
	logger.Debugf("Running %s\n", binary)
	env := os.Environ()
	execErr := syscall.Exec(binary, args, env)
	if execErr != nil {
		logger.Fatal(execErr)
	}
}
