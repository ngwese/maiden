package cmd

import (
	"os"
	"path/filepath"

	"github.com/monome/maiden/pkg/catalog"
	"github.com/spf13/viper"
)

// LoadedCatalog contains the parsed contents of a catalog file along with its path and stat info
type LoadedCatalog struct {
	Catalog  *catalog.Catalog
	FileInfo os.FileInfo
	Path     string
}

// LoadedSource contains the parsed contents of a catalog source config file along with its path and stat info
type LoadedSource struct {
	Source   *catalog.Source
	FileInfo os.FileInfo
	Path     string
}

// GetPathsForPatterns returns the paths to any file matching the file path(s)
func GetPathsForPatterns(pathPatterns []string) []string {
	paths := make([]string, 0)
	for _, pattern := range pathPatterns {
		expanded := os.ExpandEnv(pattern)
		logger.Debugf("globbing against: %s", expanded)
		matches, _ := filepath.Glob(expanded)
		for _, match := range matches {
			logger.Debugf("found match: %s", match)
			paths = append(paths, match)
		}
	}
	return paths
}

// GetCatalogPaths returns paths to all files matching the catalog search pattern(s)
func GetCatalogPaths() []string {
	catalogPatterns := viper.GetStringSlice("catalogs")
	return GetPathsForPatterns(catalogPatterns)
}

// LoadCatalogFile reads in the catalog for the given path
func LoadCatalogFile(path string) (*LoadedCatalog, error) {
	fileInfo, err := os.Stat(path)
	f, err := os.Open(path)
	defer f.Close()
	if err != nil {
		return nil, err

	}
	catalog, err := catalog.Load(f)
	if err != nil {
		return nil, err
	}

	logger.Debugf("loaded catalog: %s", path)

	return &LoadedCatalog{
		Path:     path,
		FileInfo: fileInfo,
		Catalog:  catalog,
	}, nil
}

// LoadCatalogs loads all catalogs specified in the config
func LoadCatalogs() []*LoadedCatalog {
	catalogs := make([]*LoadedCatalog, 0)

	for _, path := range GetCatalogPaths() {
		loaded, err := LoadCatalogFile(path)
		if err != nil {
			logger.Warnf("failed to load catalog %s (%s), skipping.", err, path)
			continue
		}
		catalogs = append(catalogs, loaded)
	}

	return catalogs
}

// SearchCatalogs looks for an Entry which matches the given name
func SearchCatalogs(catalogs []*LoadedCatalog, projectName string) *catalog.Entry {
	for _, loaded := range catalogs {
		if e := loaded.Catalog.Get(projectName); e != nil {
			return e
		}
	}
	return nil
}

// GetSourcePaths returns paths to all files matching the catalog source search pattern(s)
func GetSourcePaths() []string {
	sourcePatterns := viper.GetStringSlice("sources")
	return GetPathsForPatterns(sourcePatterns)
}

// LoadSourceFile reads in a catalog source config from the given file path
func LoadSourceFile(path string) (*LoadedSource, error) {
	fileInfo, err := os.Stat(path)
	f, err := os.Open(path)
	defer f.Close()
	if err != nil {
		return nil, err
	}
	source, err := catalog.LoadSource(f)
	if err != nil {
		return nil, err
	}

	return &LoadedSource{
		Path:     path,
		FileInfo: fileInfo,
		Source:   source.Source(),
	}, nil
}

// LoadSources loads in all catalog sources specified in the config
func LoadSources() []*LoadedSource {
	sources := make([]*LoadedSource, 0)
	for _, path := range GetSourcePaths() {
		logger.Debugf("loading source config from: %s", path)
		loaded, err := LoadSourceFile(path)
		if err != nil {
			logger.Warnf("failed to load catalog source info %s (%s), skipping.", err, path)
			continue
		}
		sources = append(sources, loaded)
	}
	return sources
}
