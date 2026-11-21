package dust

import (
	"archive/zip"
	"io/ioutil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/monome/maiden/pkg/catalog"
)

func TestInferProjectNameFromURL(t *testing.T) {
	cases := []struct {
		raw  string
		want string
	}{
		{"https://github.com/monome/awake", "awake"},
		{"https://github.com/monome/awake.git", "awake"},
		{"https://gitlab.com/user/myproject.git", "myproject"},
		{"https://bitbucket.org/user/repo", "repo"},
		{"https://example.com/downloads/script.zip", "script"},
		{"/tmp/archives/foo.zip", "foo"},
	}
	for _, tc := range cases {
		u, err := url.Parse(tc.raw)
		if err != nil {
			t.Fatalf("Parse(%q): %v", tc.raw, err)
		}
		got := InferProjectNameFromURL(u)
		if got != tc.want {
			t.Errorf("InferProjectNameFromURL(%q) = %q, want %q", tc.raw, got, tc.want)
		}
	}
}

func TestGetProjectsAndSearch(t *testing.T) {
	root, err := ioutil.TempDir("", "dust-projects-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(root)

	for _, name := range []string{"alpha", "beta"} {
		if err := os.Mkdir(filepath.Join(root, name), 0755); err != nil {
			t.Fatal(err)
		}
	}
	// ignored file
	if err := ioutil.WriteFile(filepath.Join(root, "readme.txt"), []byte("x"), 0644); err != nil {
		t.Fatal(err)
	}

	projects, err := GetProjects(root)
	if err != nil {
		t.Fatalf("GetProjects: %v", err)
	}
	if len(projects) != 2 {
		t.Fatalf("len(projects) = %d, want 2", len(projects))
	}
	if SearchProjects(projects, "alpha") == nil {
		t.Fatal("expected to find alpha")
	}
	if SearchProjects(projects, "missing") != nil {
		t.Fatal("missing should be nil")
	}
}

func writeZip(t *testing.T, zipPath string, files map[string]string) {
	t.Helper()
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

func TestUnzipHappyPath(t *testing.T) {
	dir, err := ioutil.TempDir("", "dust-unzip-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)

	zipPath := filepath.Join(dir, "proj.zip")
	writeZip(t, zipPath, map[string]string{
		"proj/script.lua": "-- hello",
		"proj/lib/util.lua": "return 1",
	})

	dest := filepath.Join(dir, "out")
	if err := os.Mkdir(dest, 0755); err != nil {
		t.Fatal(err)
	}
	names, err := Unzip(zipPath, dest, true)
	if err != nil {
		t.Fatalf("Unzip: %v", err)
	}
	if len(names) == 0 {
		t.Fatal("expected extracted files")
	}
	body, err := ioutil.ReadFile(filepath.Join(dest, "script.lua"))
	if err != nil {
		t.Fatalf("read script.lua: %v", err)
	}
	if string(body) != "-- hello" {
		t.Fatalf("script body = %q", body)
	}
}

func TestUnzipRejectsZipSlip(t *testing.T) {
	dir, err := ioutil.TempDir("", "dust-zipslip-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)

	zipPath := filepath.Join(dir, "bad.zip")
	f, err := os.Create(zipPath)
	if err != nil {
		t.Fatal(err)
	}
	w := zip.NewWriter(f)
	// Path that escapes dest when removeArchiveRoot is false
	zw, err := w.Create("../escape.txt")
	if err != nil {
		t.Fatal(err)
	}
	zw.Write([]byte("nope"))
	w.Close()
	f.Close()

	dest := filepath.Join(dir, "out")
	os.Mkdir(dest, 0755)
	_, err = Unzip(zipPath, dest, false)
	if err == nil {
		t.Fatal("expected ZipSlip error")
	}
	if !strings.Contains(err.Error(), "illegal file path") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestInstallLocalZip(t *testing.T) {
	root, err := ioutil.TempDir("", "dust-install-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(root)

	zipPath := filepath.Join(root, "awake.zip")
	writeZip(t, zipPath, map[string]string{
		"awake/awake.lua": "return true",
	})

	entry := &catalog.Entry{
		ProjectName: "awake",
		URL:         zipPath,
		Origin:      "test",
	}
	if err := Install(root, "awake", zipPath, entry); err != nil {
		t.Fatalf("Install: %v", err)
	}

	script := filepath.Join(root, "awake", "awake.lua")
	if _, err := os.Stat(script); err != nil {
		t.Fatalf("expected installed script: %v", err)
	}
	metaPath := filepath.Join(root, "awake", ".project")
	if _, err := os.Stat(metaPath); err != nil {
		t.Fatalf("expected .project metadata: %v", err)
	}

	p := NewProject("awake", filepath.Join(root, "awake"))
	md, err := p.GetMetaData()
	if err != nil {
		t.Fatalf("GetMetaData: %v", err)
	}
	if md.SourceURL != zipPath {
		t.Fatalf("SourceURL = %q", md.SourceURL)
	}
	if md.Entry == nil || md.Entry.ProjectName != "awake" {
		t.Fatalf("unexpected catalog entry in metadata: %+v", md.Entry)
	}

	err = Install(root, "awake", zipPath, entry)
	if err == nil {
		t.Fatal("second Install should fail because project exists")
	}
	if !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestIsManaged(t *testing.T) {
	root, err := ioutil.TempDir("", "dust-managed-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(root)

	unmanaged := filepath.Join(root, "plain")
	os.Mkdir(unmanaged, 0755)
	p := NewProject("plain", unmanaged)
	if p.IsManaged() {
		t.Fatal("plain project should not be managed")
	}

	managed := filepath.Join(root, "gitty")
	os.MkdirAll(filepath.Join(managed, ".git"), 0755)
	p = NewProject("gitty", managed)
	if !p.IsManaged() {
		t.Fatal("project with .git should be managed")
	}
}

func runGit(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-c", "protocol.file.allow=always"}, args...)...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(),
		"GIT_AUTHOR_NAME=maiden-test",
		"GIT_AUTHOR_EMAIL=maiden-test@example.com",
		"GIT_COMMITTER_NAME=maiden-test",
		"GIT_COMMITTER_EMAIL=maiden-test@example.com",
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v in %s: %v\n%s", args, dir, err, out)
	}
}

func writeVersionFile(t *testing.T, path, version string) {
	t.Helper()
	if err := ioutil.WriteFile(path, []byte(version+"\n"), 0644); err != nil {
		t.Fatal(err)
	}
}

func readVersionFile(t *testing.T, path string) string {
	t.Helper()
	data, err := ioutil.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return strings.TrimSpace(string(data))
}

// TestUpdateUpdatesSubmodules covers https://github.com/monome/maiden/issues/222:
// Install clones with RecurseSubmodules, and Update should also refresh submodule
// working trees when the parent advances the gitlink.
func TestUpdateUpdatesSubmodules(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not available")
	}

	fixture, err := ioutil.TempDir("", "dust-submodule-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(fixture)

	subBare := filepath.Join(fixture, "sub.git")
	parentBare := filepath.Join(fixture, "parent.git")
	runGit(t, "", "init", "--bare", "-b", "master", subBare)
	runGit(t, "", "init", "--bare", "-b", "master", parentBare)

	subWC := filepath.Join(fixture, "sub-wc")
	runGit(t, "", "clone", subBare, subWC)
	writeVersionFile(t, filepath.Join(subWC, "VERSION"), "1")
	runGit(t, subWC, "add", "VERSION")
	runGit(t, subWC, "commit", "-m", "submodule v1")
	runGit(t, subWC, "push", "-u", "origin", "master")

	parentWC := filepath.Join(fixture, "parent-wc")
	runGit(t, "", "clone", parentBare, parentWC)
	runGit(t, parentWC, "checkout", "-B", "master")
	writeVersionFile(t, filepath.Join(parentWC, "VERSION"), "1")
	runGit(t, parentWC, "submodule", "add", "-b", "master", subBare, "vendor/sub")
	runGit(t, parentWC, "add", "VERSION", ".gitmodules", "vendor/sub")
	runGit(t, parentWC, "commit", "-m", "parent v1 with submodule")
	runGit(t, parentWC, "push", "-u", "origin", "master")

	dustRoot := filepath.Join(fixture, "code")
	if err := os.MkdirAll(dustRoot, 0755); err != nil {
		t.Fatal(err)
	}
	if err := Install(dustRoot, "parent", parentBare, nil); err != nil {
		t.Fatalf("Install: %v", err)
	}

	installed := filepath.Join(dustRoot, "parent")
	if got := readVersionFile(t, filepath.Join(installed, "VERSION")); got != "1" {
		t.Fatalf("parent VERSION after install = %q, want 1", got)
	}
	if got := readVersionFile(t, filepath.Join(installed, "vendor", "sub", "VERSION")); got != "1" {
		t.Fatalf("submodule VERSION after install = %q, want 1", got)
	}

	// Advance submodule remote to v2, then point parent at that commit and bump parent VERSION.
	writeVersionFile(t, filepath.Join(subWC, "VERSION"), "2")
	runGit(t, subWC, "add", "VERSION")
	runGit(t, subWC, "commit", "-m", "submodule v2")
	runGit(t, subWC, "push", "origin", "master")

	runGit(t, filepath.Join(parentWC, "vendor", "sub"), "fetch", "origin")
	runGit(t, filepath.Join(parentWC, "vendor", "sub"), "checkout", "origin/master")
	writeVersionFile(t, filepath.Join(parentWC, "VERSION"), "2")
	runGit(t, parentWC, "add", "VERSION", "vendor/sub")
	runGit(t, parentWC, "commit", "-m", "parent v2 with updated submodule")
	runGit(t, parentWC, "push", "origin", "master")

	p := NewProject("parent", installed)
	updated, err := p.Update(true, nil)
	if err != nil {
		t.Fatalf("Update: %v", err)
	}
	if !updated {
		t.Fatal("expected Update to report changes")
	}

	if got := readVersionFile(t, filepath.Join(installed, "VERSION")); got != "2" {
		t.Fatalf("parent VERSION after update = %q, want 2", got)
	}
	if got := readVersionFile(t, filepath.Join(installed, "vendor", "sub", "VERSION")); got != "2" {
		t.Fatalf("submodule VERSION after update = %q, want 2 (issue #222)", got)
	}
}
