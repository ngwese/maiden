package cmd

import (
	"archive/zip"
	"bytes"
	"fmt"
	"io"
	"io/ioutil"
	"os"
	"path/filepath"
	"testing"

	"github.com/monome/maiden/pkg/catalog"
	"github.com/sirupsen/logrus"
	"github.com/spf13/viper"
)

// testEnv is an isolated maiden config + dust layout for CLI tests.
type testEnv struct {
	Root          string
	CodeDir       string
	CatalogsDir   string
	SourcesDir    string
	ConfigPath    string
	CatalogOutDir string
}

func newTestEnv(t *testing.T) *testEnv {
	t.Helper()
	root, err := ioutil.TempDir("", "maiden-cli-")
	if err != nil {
		t.Fatal(err)
	}
	env := &testEnv{
		Root:          root,
		CodeDir:       filepath.Join(root, "code"),
		CatalogsDir:   filepath.Join(root, "catalogs"),
		SourcesDir:    filepath.Join(root, "sources"),
		CatalogOutDir: filepath.Join(root, "catalogs"),
		ConfigPath:    filepath.Join(root, "maiden.yaml"),
	}
	for _, d := range []string{env.CodeDir, env.CatalogsDir, env.SourcesDir} {
		if err := os.MkdirAll(d, 0755); err != nil {
			t.Fatal(err)
		}
	}
	env.writeConfig(t)
	return env
}

func (e *testEnv) cleanup() {
	os.RemoveAll(e.Root)
}

func (e *testEnv) writeConfig(t *testing.T) {
	t.Helper()
	content := fmt.Sprintf(`sources:
  - %s/*.json
catalogOutputDir: %s
catalogs:
  - %s/*.json
dust:
  path: %s
  code: %s
`, e.SourcesDir, e.CatalogOutDir, e.CatalogsDir, e.Root, e.CodeDir)
	if err := ioutil.WriteFile(e.ConfigPath, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}
}

func resetCLIState() {
	configPath = ""
	debug = false
	updateAllProjects = false
	viper.Reset()
	logger.SetOutput(os.Stdout)
	logger.SetLevel(logrus.InfoLevel)
}

// runMaiden executes the root cobra command with --config pointed at the test env.
func (e *testEnv) runMaiden(t *testing.T, args ...string) (stdout string, err error) {
	t.Helper()
	resetCLIState()

	r, w, pipeErr := os.Pipe()
	if pipeErr != nil {
		t.Fatal(pipeErr)
	}
	oldStdout := os.Stdout
	os.Stdout = w
	logger.SetOutput(w)

	fullArgs := append([]string{"--config", e.ConfigPath}, args...)
	rootCmd.SetArgs(fullArgs)
	execErr := rootCmd.Execute()

	w.Close()
	os.Stdout = oldStdout
	logger.SetOutput(oldStdout)

	var buf bytes.Buffer
	io.Copy(&buf, r)
	r.Close()

	resetCLIState()
	return buf.String(), execErr
}

func (e *testEnv) writeCatalog(t *testing.T, name string, entries []catalog.Entry) string {
	t.Helper()
	c := catalog.New(name)
	for i := range entries {
		c.Insert(&entries[i])
	}
	path := filepath.Join(e.CatalogsDir, name+".json")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := c.Store(f); err != nil {
		t.Fatal(err)
	}
	return path
}

func (e *testEnv) writeSource(t *testing.T, name, method, url string) string {
	t.Helper()
	src := catalog.NewSourceFile(name, "", method)
	if url != "" {
		src.Source().Parameters["url"] = url
	}
	path := filepath.Join(e.SourcesDir, name+".json")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := src.StoreSource(f); err != nil {
		t.Fatal(err)
	}
	return path
}

func writeZipFixture(t *testing.T, zipPath string, files map[string]string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(zipPath), 0755); err != nil {
		t.Fatal(err)
	}
	f, err := os.Create(zipPath)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	w := zip.NewWriter(f)
	for name, body := range files {
		zw, err := w.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := zw.Write([]byte(body)); err != nil {
			t.Fatal(err)
		}
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
}
