package catalog

import (
	"encoding/json"
	"errors"
	"io"
	"io/ioutil"
)

// Source describes how to retrieve a catalog with the given name
type Source struct {
	Name string `json:"name"`
	// Destination string            `json:"destination"`
	Method     string            `json:"method"`
	Parameters map[string]string `json:"parameters"`
}

// sourceContent represents the contents of a catalog file
type sourceContent struct {
	Header Header `json:"file_info"`
	Source Source `json:"source"`
}

// SourceFile is collected information about
type SourceFile struct {
	content *sourceContent
}

var (
	sourceDefaultHeader Header
)

func init() {
	sourceDefaultHeader = Header{
		Version: 1,
		Kind:    "catalog_source",
	}
}

// NewSourceFile creates a new empty source description file
func NewSourceFile(name, destination, method string) *SourceFile {
	return &SourceFile{
		content: &sourceContent{
			Header: sourceDefaultHeader,
			Source: Source{
				Name: name,
				// Destination: destination,
				Method:     method,
				Parameters: make(map[string]string),
			},
		},
	}
}

// LoadSource loads an existing catalog source description in json form from the given reader
func LoadSource(r io.Reader) (*SourceFile, error) {
	data, err := ioutil.ReadAll(r)
	if err != nil {
		return nil, err
	}

	// TODO: deal with upgrading the
	var content sourceContent
	err = json.Unmarshal(data, &content)
	if err != nil {
		return nil, err
	}

	return &SourceFile{content: &content}, nil
}

// StoreSource writes the catalog in json form to the given writer
func (s *SourceFile) StoreSource(w io.Writer) error {
	if s.content.Header != sourceDefaultHeader {
		return errors.New("catalog source header version/kind does not match")
	}
	data, err := json.MarshalIndent(s.content, "", "  ")
	if err != nil {
		return err
	}
	_, err = w.Write(data)
	return err
}

// Source returns the source details
func (s *SourceFile) Source() *Source {
	return &s.content.Source
}
