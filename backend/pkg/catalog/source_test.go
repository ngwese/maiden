package catalog

import (
	"bytes"
	"strings"
	"testing"
)

func TestSourceRoundTrip(t *testing.T) {
	src := NewSourceFile("base", "", "download")
	src.Source().Parameters["url"] = "https://example.com/base.json"

	var buf bytes.Buffer
	if err := src.StoreSource(&buf); err != nil {
		t.Fatalf("StoreSource: %v", err)
	}

	loaded, err := LoadSource(&buf)
	if err != nil {
		t.Fatalf("LoadSource: %v", err)
	}
	got := loaded.Source()
	if got.Name != "base" || got.Method != "download" {
		t.Fatalf("unexpected source: %+v", got)
	}
	if got.Parameters["url"] != "https://example.com/base.json" {
		t.Fatalf("url = %q", got.Parameters["url"])
	}
}

func TestStoreSourceRejectsWrongHeader(t *testing.T) {
	src := NewSourceFile("base", "", "download")
	src.content.Header.Kind = "wrong"
	var buf bytes.Buffer
	err := src.StoreSource(&buf)
	if err == nil {
		t.Fatal("StoreSource should reject mismatched header")
	}
	if !strings.Contains(err.Error(), "header") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestLoadSourceFromFixtureShape(t *testing.T) {
	raw := `{
  "file_info": {
    "version": 1,
    "kind": "catalog_source"
  },
  "source": {
      "name": "base",
      "method": "download",
      "parameters": {
          "url": "https://example.com/base.json"
      }
  }
}`
	loaded, err := LoadSource(strings.NewReader(raw))
	if err != nil {
		t.Fatalf("LoadSource: %v", err)
	}
	if loaded.Source().Name != "base" {
		t.Fatalf("name = %q", loaded.Source().Name)
	}
}
