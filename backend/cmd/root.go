package cmd

import (
	"fmt"
	"log"
	"os"

	"github.com/sirupsen/logrus"

	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

// TextFormatter defines a trivial log entry formatter
type TextFormatter struct {
}

// Format performs basic formatting on log entries
func (f *TextFormatter) Format(entry *logrus.Entry) ([]byte, error) {
	return []byte(fmt.Sprintf("[%s] %s\n", entry.Level, entry.Message)), nil
}

var rootCmd = &cobra.Command{
	Use:   "maiden",
	Short: "web editor for norns scripts",
}

var (
	configPath string
	debug      bool
	logger     *logrus.Logger
)

func init() {
	rootCmd.PersistentFlags().BoolVar(&debug, "debug", false, "enable debug logging")
	rootCmd.PersistentFlags().StringVar(&configPath, "config", "", "use specific config file")

	// initialize default logging configuration
	logger = logrus.New()
	logger.SetOutput(os.Stdout)
	logger.SetLevel(logrus.InfoLevel)
	logger.SetFormatter(&TextFormatter{})
}

// Execute add all child commands to the root command and defaults flags
// appropriately (called from main.main())
func Execute() {
	if err := rootCmd.Execute(); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
}

// CheckErrorFatal logs a fatal error if error value is non-nil
func CheckErrorFatal(e error) {
	if e != nil {
		log.Fatal(e)
	}
}

// CheckErrorNonFatal logs the error if error value is non-nil, returning true if there was an error
func CheckErrorNonFatal(e error, ok string) bool {
	if e != nil {
		log.Println(e)
		return true
	}
	log.Println(ok)
	return false
}

// ConfigureLogger tweaks the configuration of the global logger based on parsed
// command line flags
func ConfigureLogger() {
	if debug {
		logger.SetLevel(logrus.DebugLevel)
	}
}

// LoadConfiguration attempts to load in external configuration if possible, this function must be called in each commands execute function (after argument processing) because its behavior is influenced by the command line itself
func LoadConfiguration() {
	if configPath == "" {
		viper.SetConfigName("maiden")
		viper.SetConfigType("yaml")

		// config seach path; ordered from strongest to weakest
		viper.AddConfigPath(".")
		viper.AddConfigPath("$HOME/maiden")
		viper.AddConfigPath("$HOME/.config/maiden")
		viper.AddConfigPath("/etc")
	} else {

		viper.SetConfigFile(configPath)
	}

	viper.ReadInConfig()

	logger.Debugf("used confg: %s", viper.ConfigFileUsed())
	// 	if debug {
	// 		viper.Debug()
	// 	}
}
