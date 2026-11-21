package catalog

import (
	"bytes"
	"strings"
	"testing"
)

func TestNew(t *testing.T) {
	c := New("demo")
	if c.Name() != "demo" {
		t.Fatalf("Name() = %q, want %q", c.Name(), "demo")
	}
	if len(c.Entries()) != 0 {
		t.Fatalf("Entries() len = %d, want 0", len(c.Entries()))
	}
	if c.content.Header.Version != 1 || c.content.Header.Kind != "script_catalog" {
		t.Fatalf("unexpected header: %+v", c.content.Header)
	}
}

func TestInsertGetAndReplace(t *testing.T) {
	c := New("demo")
	c.Insert(&Entry{
		ProjectName: "awake",
		URL:         "https://example.com/awake.zip",
		Origin:      "base",
		Tags:        []string{"utility"},
	})

	got := c.Get("awake")
	if got == nil {
		t.Fatal("Get(awake) returned nil")
	}
	if got.URL != "https://example.com/awake.zip" {
		t.Fatalf("URL = %q, want example zip", got.URL)
	}
	if c.Get("missing") != nil {
		t.Fatal("Get(missing) should be nil")
	}

	c.Insert(&Entry{
		ProjectName: "awake",
		URL:         "https://example.com/awake-v2.zip",
		Origin:      "community",
	})
	if len(c.Entries()) != 1 {
		t.Fatalf("Entries() len = %d after replace, want 1", len(c.Entries()))
	}
	got = c.Get("awake")
	if got.URL != "https://example.com/awake-v2.zip" || got.Origin != "community" {
		t.Fatalf("replace failed: %+v", got)
	}
}

func TestStoreLoadRoundTrip(t *testing.T) {
	c := New("roundtrip")
	c.Insert(&Entry{
		ProjectName: "foo",
		URL:         "https://example.com/foo.git",
		Description: "a script",
		Tags:        []string{"a", "b"},
	})

	var buf bytes.Buffer
	if err := c.Store(&buf); err != nil {
		t.Fatalf("Store: %v", err)
	}

	loaded, err := Load(&buf)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if loaded.Name() != "roundtrip" {
		t.Fatalf("Name() = %q, want roundtrip", loaded.Name())
	}
	entry := loaded.Get("foo")
	if entry == nil {
		t.Fatal("loaded catalog missing foo")
	}
	if entry.Description != "a script" || entry.URL != "https://example.com/foo.git" {
		t.Fatalf("unexpected entry: %+v", entry)
	}
}

func TestStoreRejectsWrongHeader(t *testing.T) {
	c := New("bad")
	c.content.Header.Kind = "not_a_catalog"
	var buf bytes.Buffer
	err := c.Store(&buf)
	if err == nil {
		t.Fatal("Store should reject mismatched header")
	}
	if !strings.Contains(err.Error(), "header") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestLoadInvalidJSON(t *testing.T) {
	_, err := Load(strings.NewReader("{not-json"))
	if err == nil {
		t.Fatal("Load should fail on invalid JSON")
	}
}
