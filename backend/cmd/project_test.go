package cmd

import (
	"io/ioutil"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/monome/maiden/pkg/catalog"
)

func TestProjectList(t *testing.T) {
	env := newTestEnv(t)
	defer env.cleanup()

	for _, name := range []string{"alpha", "beta"} {
		if err := os.Mkdir(filepath.Join(env.CodeDir, name), 0755); err != nil {
			t.Fatal(err)
		}
	}

	out, err := env.runMaiden(t, "project", "list")
	if err != nil {
		t.Fatalf("Execute: %v\nstdout: %s", err, out)
	}
	if !strings.Contains(out, "alpha") || !strings.Contains(out, "beta") {
		t.Fatalf("expected both projects in list:\n%s", out)
	}
	if !strings.Contains(out, "project") || !strings.Contains(out, "git") {
		t.Fatalf("expected column headers:\n%s", out)
	}
}

func TestProjectListFilterAndUnknown(t *testing.T) {
	env := newTestEnv(t)
	defer env.cleanup()

	if err := os.Mkdir(filepath.Join(env.CodeDir, "alpha"), 0755); err != nil {
		t.Fatal(err)
	}

	out, err := env.runMaiden(t, "project", "list", "alpha")
	if err != nil {
		t.Fatalf("Execute: %v\nstdout: %s", err, out)
	}
	if !strings.Contains(out, "alpha") {
		t.Fatalf("expected alpha:\n%s", out)
	}

	out, err = env.runMaiden(t, "project", "list", "missing")
	if err != nil {
		t.Fatalf("Execute: %v\nstdout: %s", err, out)
	}
	if !strings.Contains(out, "Unknown project") {
		t.Fatalf("expected unknown warning:\n%s", out)
	}
}

func TestProjectInstallFromCatalog(t *testing.T) {
	env := newTestEnv(t)
	defer env.cleanup()

	zipPath := filepath.Join(env.Root, "awake.zip")
	writeZipFixture(t, zipPath, map[string]string{
		"awake/awake.lua": "return true",
	})

	env.writeCatalog(t, "base", []catalog.Entry{
		{
			ProjectName: "awake",
			URL:         zipPath,
			Origin:      "base",
			Description: "test script",
		},
	})

	out, err := env.runMaiden(t, "project", "install", "awake")
	if err != nil {
		t.Fatalf("Execute: %v\nstdout: %s", err, out)
	}
	if !strings.Contains(out, "Installing: awake") || !strings.Contains(out, "done.") {
		t.Fatalf("unexpected install output:\n%s", out)
	}
	if _, err := os.Stat(filepath.Join(env.CodeDir, "awake", "awake.lua")); err != nil {
		t.Fatalf("installed script missing: %v", err)
	}
}

func TestProjectInstallFromURL(t *testing.T) {
	env := newTestEnv(t)
	defer env.cleanup()

	zipPath := filepath.Join(env.Root, "downloads", "myscript.zip")
	writeZipFixture(t, zipPath, map[string]string{
		"myscript/main.lua": "-- hi",
	})

	out, err := env.runMaiden(t, "project", "install", zipPath)
	if err != nil {
		t.Fatalf("Execute: %v\nstdout: %s", err, out)
	}
	if !strings.Contains(out, "Installing: myscript") {
		t.Fatalf("expected inferred name myscript:\n%s", out)
	}
	if _, err := os.Stat(filepath.Join(env.CodeDir, "myscript", "main.lua")); err != nil {
		t.Fatalf("installed script missing: %v", err)
	}
}

func TestProjectRemove(t *testing.T) {
	env := newTestEnv(t)
	defer env.cleanup()

	proj := filepath.Join(env.CodeDir, "gone")
	if err := os.Mkdir(proj, 0755); err != nil {
		t.Fatal(err)
	}
	ioutil.WriteFile(filepath.Join(proj, "x.lua"), []byte("x"), 0644)

	out, err := env.runMaiden(t, "project", "remove", "gone")
	if err != nil {
		t.Fatalf("Execute: %v\nstdout: %s", err, out)
	}
	if !strings.Contains(out, "Removing: gone") || !strings.Contains(out, "done.") {
		t.Fatalf("unexpected remove output:\n%s", out)
	}
	if _, err := os.Stat(proj); !os.IsNotExist(err) {
		t.Fatal("project dir should be removed")
	}

	out, err = env.runMaiden(t, "project", "remove", "gone")
	if err != nil {
		t.Fatalf("Execute: %v\nstdout: %s", err, out)
	}
	if !strings.Contains(out, "Unknown project") {
		t.Fatalf("expected unknown after remove:\n%s", out)
	}
}

func TestProjectUpdateNonGit(t *testing.T) {
	env := newTestEnv(t)
	defer env.cleanup()

	zipPath := filepath.Join(env.Root, "awake.zip")
	writeZipFixture(t, zipPath, map[string]string{
		"awake/awake.lua": "v1",
	})
	env.writeCatalog(t, "base", []catalog.Entry{
		{ProjectName: "awake", URL: zipPath, Origin: "base"},
	})

	// Pre-install an older copy without going through catalog install
	oldDir := filepath.Join(env.CodeDir, "awake")
	if err := os.Mkdir(oldDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := ioutil.WriteFile(filepath.Join(oldDir, "awake.lua"), []byte("old"), 0644); err != nil {
		t.Fatal(err)
	}

	// Rewrite zip with new content for the update reinstall
	writeZipFixture(t, zipPath, map[string]string{
		"awake/awake.lua": "v2",
	})

	out, err := env.runMaiden(t, "project", "update", "awake")
	if err != nil {
		t.Fatalf("Execute: %v\nstdout: %s", err, out)
	}
	if !strings.Contains(out, "Updating: awake") {
		t.Fatalf("unexpected update output:\n%s", out)
	}
	body, err := ioutil.ReadFile(filepath.Join(env.CodeDir, "awake", "awake.lua"))
	if err != nil {
		t.Fatalf("read updated script: %v", err)
	}
	if string(body) != "v2" {
		t.Fatalf("script body = %q, want v2", body)
	}
}

func TestProjectUpdateAll(t *testing.T) {
	env := newTestEnv(t)
	defer env.cleanup()

	zipPath := filepath.Join(env.Root, "one.zip")
	writeZipFixture(t, zipPath, map[string]string{
		"one/one.lua": "new",
	})
	env.writeCatalog(t, "base", []catalog.Entry{
		{ProjectName: "one", URL: zipPath, Origin: "base"},
	})

	oldDir := filepath.Join(env.CodeDir, "one")
	os.Mkdir(oldDir, 0755)
	ioutil.WriteFile(filepath.Join(oldDir, "one.lua"), []byte("old"), 0644)

	out, err := env.runMaiden(t, "project", "update", "--all")
	if err != nil {
		t.Fatalf("Execute: %v\nstdout: %s", err, out)
	}
	if !strings.Contains(out, "Updating: one") {
		t.Fatalf("unexpected output:\n%s", out)
	}
	body, _ := ioutil.ReadFile(filepath.Join(env.CodeDir, "one", "one.lua"))
	if string(body) != "new" {
		t.Fatalf("body = %q, want new", body)
	}
}
