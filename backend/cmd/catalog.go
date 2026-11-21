package cmd

import (
	"fmt"
	"log"
	"os"
	"path/filepath"

	"text/tabwriter"

	"github.com/monome/maiden/pkg/catalog"
	"github.com/spf13/cobra"
)

var catalogCmd = &cobra.Command{
	Use:   "catalog",
	Short: "manage the script catalog",
	Args:  cobra.NoArgs,
}

var catalogListCmd = &cobra.Command{
	Use:   "list",
	Short: "list projects",
	Run: func(cmd *cobra.Command, args []string) {
		ConfigureLogger()
		LoadConfiguration()
		catalogListRun(args)
	},
}

var catalogInitCmd = &cobra.Command{
	Use:   "init",
	Short: "init an empty catalog file",
	Args:  cobra.RangeArgs(1, 1),
	Run: func(cmd *cobra.Command, args []string) {
		ConfigureLogger()
		LoadConfiguration()
		catalogInitRun(args)
	},
}

func init() {
	catalogCmd.AddCommand(catalogListCmd)
	catalogCmd.AddCommand(catalogInitCmd)
	rootCmd.AddCommand(catalogCmd)
}

func catalogListRun(args []string) {
	w := new(tabwriter.Writer)
	w.Init(os.Stdout, 0, 8, 0, '\t', 0) // FIXME: magic numbers?

	catalogs := LoadCatalogs()
	if len(catalogs) == 0 {
		logger.Warn("no catalog files loaded")
		return
	}

	for _, loaded := range catalogs {
		fmt.Fprintf(os.Stdout, "[ %s ]\n", loaded.Path)
		fmt.Fprintln(w, "project\tsource\turl\ttags\t")
		fmt.Fprintln(w, "-------\t------\t---\t----\t")
		for _, entry := range loaded.Catalog.Entries() {
			fmt.Fprintf(w, "%s\t%s\t%s\t%s\t\n", entry.ProjectName, entry.Origin, entry.URL, entry.Tags)
		}
		w.Flush()
	}
}

func catalogInitRun(args []string) {
	// default the catalog name to the base name of the file minus extension
	name := filepath.Base(args[0])
	extension := filepath.Ext(name)
	name = name[0 : len(name)-len(extension)]

	c := catalog.New(name)
	logger.Debug("creating file: ", args[0])
	f, err := os.Create(args[0])
	if err != nil {
		log.Fatalln(err)
	}
	defer f.Close()
	c.Store(f)
	fmt.Printf("Wrote: %s\n", args[0])
}
