package cmd

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"

	"github.com/monome/maiden/pkg/catalog"
	"github.com/monome/maiden/pkg/lines"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

var catalogUpdateCmd = &cobra.Command{
	Use:   "update",
	Short: "update configured catalogs",
	Run: func(cmd *cobra.Command, args []string) {
		ConfigureLogger()
		LoadConfiguration()
		CatalogUpdateRun(args)
	},
}

func init() {
	catalogCmd.AddCommand(catalogUpdateCmd)
}

// FIXME: merge this with pkg/dust/project.go:downloadURL
func downloadURLToFile(filepath string, url string) error {
	logger.Debug("downloading: ", url)
	resp, err := http.Get(url)
	if err != nil {
		logger.Debug("url get failed: ", err)
		return err
	}

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download failed for %s, status: %d", url, resp.StatusCode)
	}

	defer resp.Body.Close()

	logger.Debug("creating file: ", filepath)
	f, err := os.Create(filepath)
	if err != nil {
		return err
	}
	defer f.Close()

	n, err := io.Copy(f, resp.Body)
	logger.Debugf("wrote %d bytes, error = %s", n, err)
	return err
}

func contains(arr []string, str string) bool {
	for _, a := range arr {
		if a == str {
			return true
		}
	}
	return false
}

// CatalogUpdateRun updates the specified catalogs based on their source configuration
func CatalogUpdateRun(args []string) {
	sources := LoadSources()
	if sources == nil {
		logger.Fatalf("unable to load catalog sources")
	}

	for _, loaded := range sources {
		sourceName := loaded.Source.Name

		// filter out sources if an explicit list is provided
		if len(args) > 0 && !contains(args, sourceName) {
			logger.Debugf("source '%s' not in update list, skipping", sourceName)
			continue
		}

		// ensure we have a method
		sourceMethod := loaded.Source.Method
		if sourceMethod == "" {
			logger.Warnf("source 'method' not specified for '%s', skipping", sourceName)
			continue
		}

		// compute output path
		outputDir := viper.GetString("catalogOutputDir")
		outputPath := os.ExpandEnv(filepath.Join(outputDir, sourceName+".json"))

		fmt.Printf("Updating: %s; ", sourceName)
		switch sourceMethod {
		case "lines":
			GenerateCatalogFromLines(loaded.Source, outputPath)
		case "download":
			DownloadCatalog(loaded.Source, outputPath)
		default:
			fmt.Println("unrecognized catalog source:", sourceMethod)
		}
	}
}

// GenerateCatalogFromLines constructs a new catalog by gathering project information from lines and writes it to the given path
func GenerateCatalogFromLines(source *catalog.Source, outputPath string) {
	// default the catalog name to the base name of the file minus extension
	name := filepath.Base(outputPath)
	extension := filepath.Ext(name)
	name = name[0 : len(name)-len(extension)]

	fmt.Printf("fetching topics from lines... ")
	catalog := catalog.New(name)
	err := lines.GatherProjects(catalog)
	if err != nil {
		log.Fatalf("failed while gathering project: %s", err)
	}

	logger.Debug("creating file: ", outputPath)
	destination, err := os.Create(outputPath)
	if err != nil {
		log.Fatalf("%s", err)
	}
	defer destination.Close()

	err = catalog.Store(destination)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("wrote: %s\n", outputPath)
}

// DownloadCatalog downloads the catalog from the location given in the source and writes it to the given path
func DownloadCatalog(source *catalog.Source, outputPath string) {
	url, ok := source.Parameters["url"]
	if !ok {
		logger.Warnf("missing 'url' value config for source: %s, skipping.", source.Name)
		return
	}

	fmt.Printf("fetching %s... ", url)
	if err := downloadURLToFile(outputPath, url); err != nil {
		logger.Warn(err)
	}
	fmt.Printf("wrote: %s\n", outputPath)
}
