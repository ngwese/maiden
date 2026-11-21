package dust

import (
	"io/ioutil"
	"log"
	"os"
	"path/filepath"
)

var reservedNames = map[string]bool{
	"audio": true,
	"data":  true,
}

// Layout describes a dust directory structure
type Layout struct {
	RootDir string
}

// DefaultDustRoot returns the default root directory path for dust
func DefaultDustRoot() string {
	value, exists := os.LookupEnv("HOME")
	if !exists {
		log.Fatalf("HOME env not set, unable to determine default dust directory")
	}
	return filepath.Join(value, "dust")
}

// NewLayout creates a new (directory) Layout
func NewLayout(rootDir string) *Layout {
	return &Layout{
		RootDir: rootDir,
	}
}

// AudioDir returns the path to the audio directory for the given root directory
func (l *Layout) AudioDir() string {
	return filepath.Join(l.RootDir, "audio")
}

// TapeDir returns the path to the tape functions audio directory for the given root directory
func (l *Layout) TapeDir() string {
	return filepath.Join(l.AudioDir(), "tape")
}

// DataDir returns the path to the data directory for the given root directory
func (l *Layout) DataDir() string {
	return filepath.Join(l.RootDir, "data")
}

// ProjectsDir require the path to the directory containing projects
func (l *Layout) ProjectsDir() string {
	return l.RootDir
}

// CreateProject creates a new project directory with the given name if it does not already exist, returning a new Project on success
func (l *Layout) CreateProject(name string) (*Project, error) {
	parent := l.ProjectsDir()
	root := filepath.Join(parent, name)
	if err := os.Mkdir(root, 755); err != nil {
		return nil, err
	}
	return NewProject(name, root), nil
}

// GetProjects returns an array of Project(s), one for each project directory in the layout
func (l *Layout) GetProjects() *[]Project {
	var projects = []Project{}
	projectsDir := l.ProjectsDir()
	dirs, err := ioutil.ReadDir(projectsDir)
	if err != nil {
		return nil
	}
	for _, entry := range dirs {
		if !reservedNames[entry.Name()] && entry.IsDir() {
			projects = append(projects, *NewProject(entry.Name(), filepath.Join(projectsDir, entry.Name())))
		}
	}
	return &projects
}

// GetProject returns
func (l *Layout) GetProject(name string) *Project {
	if reservedNames[name] {
		return nil
	}
	d := filepath.Join(l.ProjectsDir(), name)
	if stat, err := os.Lstat(d); err == nil && stat.IsDir() {
		return NewProject(name, d)
	}
	return nil
}

// EnsureDirectories creates any of the standard directories if they do not exist
func (l *Layout) EnsureDirectories() error {
	var directories = []string{l.DataDir(), l.AudioDir(), l.TapeDir()}
	for _, d := range directories {
		err := os.MkdirAll(d, 0755)
		if err != nil {
			return err
		}
	}
	return nil
}
