package cmd

import (
	"io/ioutil"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/monome/maiden/pkg/catalog"
)

func TestCatalogInit(t *testing.T) {
	env := newTestEnv(t)
	defer env.cleanup()

	outPath := filepath.Join(env.Root, "mycatalog.json")
	out, err := env.runMaiden(t, "catalog", "init", outPath)
	if err != nil {
		t.Fatalf("Execute: %v\nstdout: %s", err, out)
	}
	if !strings.Contains(out, "Wrote:") {
		t.Fatalf("expected Wrote message, got: %s", out)
	}

	f, err := os.Open(outPath)
	if err != nil {
		t.Fatalf("open created catalog: %v", err)
	}
	defer f.Close()
	c, err := catalog.Load(f)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if c.Name() != "mycatalog" {
		t.Fatalf("catalog name = %q, want mycatalog", c.Name())
	}
	if len(c.Entries()) != 0 {
		t.Fatalf("expected empty catalog")
	}
}

func TestCatalogList(t *testing.T) {
	env := newTestEnv(t)
	defer env.cleanup()

	env.writeCatalog(t, "base", []catalog.Entry{
		{
			ProjectName: "awake",
			URL:         "https://example.com/awake.zip",
			Origin:      "base",
			Tags:        []string{"utility"},
		},
	})

	out, err := env.runMaiden(t, "catalog", "list")
	if err != nil {
		t.Fatalf("Execute: %v\nstdout: %s", err, out)
	}
	for _, want := range []string{"awake", "base", "https://example.com/awake.zip", "project"} {
		if !strings.Contains(out, want) {
			t.Fatalf("stdout missing %q:\n%s", want, out)
		}
	}
}

func TestCatalogListEmpty(t *testing.T) {
	env := newTestEnv(t)
	defer env.cleanup()

	out, err := env.runMaiden(t, "catalog", "list")
	if err != nil {
		t.Fatalf("Execute: %v\nstdout: %s", err, out)
	}
	if !strings.Contains(out, "no catalog files loaded") {
		t.Fatalf("expected warn about empty catalogs, got: %s", out)
	}
}

func TestCatalogUpdateDownload(t *testing.T) {
	env := newTestEnv(t)
	defer env.cleanup()

	body := `{"file_info":{"version":1,"kind":"script_catalog"},"catalog_name":"served","entries":[{"project_name":"fromserver","project_url":"https://example.com/x.zip","description":""}]}`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(body))
	}))
	defer srv.Close()

	env.writeSource(t, "base", "download", srv.URL)

	out, err := env.runMaiden(t, "catalog", "update")
	if err != nil {
		t.Fatalf("Execute: %v\nstdout: %s", err, out)
	}
	if !strings.Contains(out, "Updating: base") {
		t.Fatalf("unexpected stdout: %s", out)
	}

	dest := filepath.Join(env.CatalogOutDir, "base.json")
	data, err := ioutil.ReadFile(dest)
	if err != nil {
		t.Fatalf("read downloaded catalog: %v", err)
	}
	if string(data) != body {
		t.Fatalf("catalog body mismatch:\ngot:  %s\nwant: %s", data, body)
	}
}

func TestCatalogUpdateFiltersByName(t *testing.T) {
	env := newTestEnv(t)
	defer env.cleanup()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"ok":true}`))
	}))
	defer srv.Close()

	env.writeSource(t, "base", "download", srv.URL)
	env.writeSource(t, "community", "download", srv.URL+"/community")

	out, err := env.runMaiden(t, "catalog", "update", "community")
	if err != nil {
		t.Fatalf("Execute: %v\nstdout: %s", err, out)
	}
	if !strings.Contains(out, "Updating: community") {
		t.Fatalf("expected community update, got: %s", out)
	}
	if strings.Contains(out, "Updating: base") {
		t.Fatalf("base should have been skipped, got: %s", out)
	}
	if _, err := os.Stat(filepath.Join(env.CatalogOutDir, "community.json")); err != nil {
		t.Fatalf("community.json missing: %v", err)
	}
	if _, err := os.Stat(filepath.Join(env.CatalogOutDir, "base.json")); !os.IsNotExist(err) {
		t.Fatal("base.json should not exist when filtered out")
	}
}

func TestCatalogUpdateUnrecognizedMethod(t *testing.T) {
	env := newTestEnv(t)
	defer env.cleanup()

	env.writeSource(t, "weird", "telepathy", "")

	out, err := env.runMaiden(t, "catalog", "update")
	if err != nil {
		t.Fatalf("Execute: %v\nstdout: %s", err, out)
	}
	if !strings.Contains(out, "unrecognized catalog source") {
		t.Fatalf("expected unrecognized message, got: %s", out)
	}
}

func TestSearchCatalogsHelper(t *testing.T) {
	env := newTestEnv(t)
	defer env.cleanup()

	env.writeCatalog(t, "base", []catalog.Entry{
		{ProjectName: "awake", URL: "https://example.com/awake.zip"},
	})

	resetCLIState()
	viperSetConfig(t, env.ConfigPath)
	catalogs := LoadCatalogs()
	entry := SearchCatalogs(catalogs, "awake")
	if entry == nil || entry.ProjectName != "awake" {
		t.Fatalf("SearchCatalogs failed: %+v", entry)
	}
	if SearchCatalogs(catalogs, "nope") != nil {
		t.Fatal("expected nil for missing project")
	}
}

func viperSetConfig(t *testing.T, path string) {
	t.Helper()
	configPath = path
	LoadConfiguration()
}

func TestGetPathsForPatterns(t *testing.T) {
	dir, err := ioutil.TempDir("", "maiden-glob-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)

	a := filepath.Join(dir, "a.json")
	b := filepath.Join(dir, "b.json")
	ioutil.WriteFile(a, []byte("{}"), 0644)
	ioutil.WriteFile(b, []byte("{}"), 0644)

	paths := GetPathsForPatterns([]string{filepath.Join(dir, "*.json")})
	if len(paths) != 2 {
		t.Fatalf("len(paths) = %d, want 2 (%v)", len(paths), paths)
	}
}
