package cmd

import (
	"fmt"

	"github.com/spf13/cobra"
)

var (
	version string = "development"
	compileTime string
)

// Version constructs the formatted version string.
func Version() string {
	if compileTime != "" {
		return fmt.Sprintf("%s / %s", version, compileTime)
	}
	return version
}

var versionCmd = &cobra.Command{
	Use:   "version",
	Short: "print maiden version",
	Args:  cobra.NoArgs,
	Run: func(cmd *cobra.Command, args []string) {
		ConfigureLogger()
		LoadConfiguration()
		fmt.Println(Version())
	},
}

func init() {
	rootCmd.AddCommand(versionCmd)
}
