package cmd

import (
	"fmt"
	"log"
	"net/url"
	"os"
	"text/tabwriter"

	"github.com/spf13/cobra"
	"github.com/spf13/viper"

	"github.com/monome/maiden/pkg/dust"
)

var projectCmd = &cobra.Command{
	Use:   "project",
	Short: "manage dust projects",
}

var listProjectsCmd = &cobra.Command{
	Use:   "list [names]",
	Short: "list installed script/project(s)",
	Run: func(cmd *cobra.Command, args []string) {
		ConfigureLogger()
		LoadConfiguration()
		listProjectsRun(args)
	},
}

var installProjectCmd = &cobra.Command{
	Use:   "install <names or urls>",
	Short: "install a script/project",
	Args:  cobra.MinimumNArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		ConfigureLogger()
		LoadConfiguration()
		installProjectRun(args)
	},
}

var updateProjectCmd = &cobra.Command{
	Use:   "update [names]",
	Short: "update a script/project",
	// Args:  cobra.,
	Run: func(cmd *cobra.Command, args []string) {
		ConfigureLogger()
		LoadConfiguration()
		updateProjectRun(args)
	},
}

var pushProjectCmd = &cobra.Command{
	Use:   "push",
	Short: "push a git based project",
	// Args:  cobra.,
	Run: func(cmd *cobra.Command, args []string) {
		ConfigureLogger()
		LoadConfiguration()
		pushProjectRun(args)
	},
}

var removeProjectCmd = &cobra.Command{
	Use:   "remove <names>",
	Short: "remove a project dir",
	Args:  cobra.MinimumNArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		ConfigureLogger()
		LoadConfiguration()
		removeProjectRun(args)
	},
}

var (
	updateAllProjects bool
)

func init() {
	updateProjectCmd.Flags().BoolVar(&updateAllProjects, "all", false, "update all installed projects")

	projectCmd.AddCommand(listProjectsCmd)
	projectCmd.AddCommand(installProjectCmd)
	projectCmd.AddCommand(updateProjectCmd)
	projectCmd.AddCommand(pushProjectCmd)
	projectCmd.AddCommand(removeProjectCmd)
	rootCmd.AddCommand(projectCmd)
}

func ensureDustCodeRoot() string {
	// ensure dust dir
	p := os.ExpandEnv(viper.GetString("dust.code"))
	logger.Debug("using configured dust dir: ", p)

	if _, err := os.Stat(p); os.IsNotExist(err) {
		logger.Fatalf("dust directory '%s' does not exist", p)
	}
	return p
}

func listProjectsRun(args []string) {
	dustRoot := ensureDustCodeRoot()

	// load projects
	projects, err := dust.GetProjects(dustRoot)
	CheckErrorFatal(err)

	// select which projects to list
	var candidates []*dust.Project
	candidates = make([]*dust.Project, 0)
	if len(args) == 0 {
		candidates = projects
	} else {
		for _, name := range args {
			if p := dust.SearchProjects(projects, name); p != nil {
				candidates = append(candidates, p)
			} else {
				logger.Warning("Unknown project: ", name)
			}
		}
	}

	if len(candidates) > 0 {
		w := new(tabwriter.Writer)
		w.Init(os.Stdout, 0, 8, 0, '\t', 0) // FIXME: magic numbers?
		fmt.Fprintln(w, "project\tgit\tversion\tdir\t")
		fmt.Fprintln(w, "-------\t---\t-------\t---\t")

		// do the work
		for _, p := range candidates {
			if p.IsManaged() {
				version, _ := p.GetVersion()
				fmt.Fprintf(w, "%s\t%v\t%s\t%s\t\n", p.Name, true, version, p.Root)
			} else {
				fmt.Fprintf(w, "%s\t%v\t%s\t%s\t\n", p.Name, false, "", p.Root)
			}
		}
		w.Flush()
	}
}

func installProjectRun(args []string) {
	// load catalog(s)
	catalogs := LoadCatalogs()
	if catalogs == nil {
		log.Fatalf("unable to load script catalog(s)")
	}

	root := ensureDustCodeRoot()

	// install projects
	for _, name := range args {
		var projectURL string
		var projectName string

		// first, assume the arg is a project name
		entry := SearchCatalogs(catalogs, name)
		if entry != nil {
			projectURL = entry.URL
			projectName = entry.ProjectName
		} else {
			// not a known project, assume it is a url
			projectURL = name
			parsed, err := url.Parse(name)
			if err != nil {
				fmt.Printf("invalid project url: %s, skipping\n", name)
				continue
			}
			projectName = dust.InferProjectNameFromURL(parsed)
		}

		fmt.Printf("Installing: %s (%s)... ", projectName, projectURL)
		err := dust.Install(root, projectName, projectURL, entry)
		if err != nil {
			fmt.Printf("failed: %s\n", err)
		} else {
			fmt.Printf("done.\n")
		}
	}
}

func updateProjectRun(args []string) {
	dustRoot := ensureDustCodeRoot()

	// load catalog(s)
	catalogs := LoadCatalogs()
	if catalogs == nil {
		logger.Fatal("unable to load script catalog(s)")
	}

	// load projects
	logger.Debug("getting projects from: ", dustRoot)
	projects, err := dust.GetProjects(dustRoot)
	CheckErrorFatal(err)

	// select which projects to update
	var candidates []*dust.Project
	candidates = make([]*dust.Project, 0)
	if updateAllProjects {
		candidates = projects
	} else {
		for _, name := range args {
			if p := dust.SearchProjects(projects, name); p != nil {
				candidates = append(candidates, p)
			} else {
				fmt.Println("Unknown project:", name)
			}
		}
	}

	// do the work
	for _, p := range candidates {
		fmt.Printf("Updating: %s ... ", p.Name)
		if p.IsManaged() {
			err = p.Update(true)
			CheckErrorNonFatal(err, "done.")
		} else {
			// assume zip
			if entry := SearchCatalogs(catalogs, p.Name); entry != nil {
				// TODO: only remove if download succeds?
				os.RemoveAll(p.Root)
				err = dust.Install(dustRoot, p.Name, entry.URL, entry)
				CheckErrorNonFatal(err, "done.")
			} else {
				fmt.Printf("failed: cannot find in catalog")
			}
		}
	}
}

func pushProjectRun(args []string) {
	log.Printf("args: %+v", args)
}

func removeProjectRun(args []string) {
	dustRoot := ensureDustCodeRoot()
	logger.Debug("getting projects from: ", dustRoot)
	projects, err := dust.GetProjects(dustRoot)
	CheckErrorFatal(err)

	for _, name := range args {
		if project := dust.SearchProjects(projects, name); project != nil {
			fmt.Printf("Removing: %s (%s)... ", project.Name, project.Root)
			os.RemoveAll(project.Root)
			fmt.Println("done.")
		} else {
			fmt.Printf("Unknown project: '%s'\n", name)
		}
	}
}
