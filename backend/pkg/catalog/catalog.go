package catalog

import (
	"encoding/json"
	"errors"
	"io"
	"io/ioutil"
	"time"
)

// Entry contains the properties of a project which are recorded as part of the catalog
type Entry struct {
	ProjectName   string   `json:"project_name"`
	URL           string   `json:"project_url,omitempty"`
	Author        string   `json:"author,omitempty"`
	Homepage      string   `json:"home_page,omitempty"`
	Description   string   `json:"description"`
	Discussion    string   `json:"discussion_url,omitempty"`
	Documentation string   `json:"documentation_url,omitempty"`
	Tags          []string `json:"tags,omitempty"`
	Version       string   `json:"version,omitempty"`
	Origin        string   `json:"origin,omitempty"`
}

// catalogContent represents the contents of a catalog file
type catalogContent struct {
	Header  Header    `json:"file_info"`
	Name    string    `json:"catalog_name"`
	Date    time.Time `json:"date,omitempty"`
	Entries []Entry   `json:"entries"`
}

// Catalog is collected information about
type Catalog struct {
	content *catalogContent
}

var (
	catalogDefaultHeader Header
)

func init() {
	catalogDefaultHeader = Header{
		Version: 1,
		Kind:    "script_catalog",
	}
}

// New creates a new empty catalog
func New(name string) *Catalog {
	return &Catalog{
		content: &catalogContent{
			Name:    name,
			Header:  catalogDefaultHeader,
			Entries: make([]Entry, 0),
		},
	}
}

// Load loads an existing catalog in json form from the given reader
func Load(r io.Reader) (*Catalog, error) {
	data, err := ioutil.ReadAll(r)
	if err != nil {
		return nil, err
	}

	// TODO: deal with upgrading the
	var content catalogContent
	err = json.Unmarshal(data, &content)
	if err != nil {
		return nil, err
	}

	return &Catalog{content: &content}, nil
}

// Store writes the catalog in json form to the given writer
func (c *Catalog) Store(w io.Writer) error {
	if c.content.Header != catalogDefaultHeader {
		return errors.New("catalog header version/kind does not match")
	}
	data, err := json.MarshalIndent(c.content, "", "  ")
	if err != nil {
		return err
	}
	_, err = w.Write(data)
	return err
}

// Insert places the given entry in the catalog potentially replacing an entry
// with the name name
func (c *Catalog) Insert(entry *Entry) {
	for i, e := range c.content.Entries {
		if e.ProjectName == entry.ProjectName {
			c.content.Entries[i] = *entry
			return
		}
	}
	// else we haven't found a matching entry, append
	c.content.Entries = append(c.content.Entries, *entry)
}

// Get returns the first matching entry found in the catalog or nil
func (c *Catalog) Get(name string) *Entry {
	for _, e := range c.content.Entries {
		if e.ProjectName == name {
			return &e
		}
	}
	return nil
}

// Entries returns all the entries in the catalog
func (c *Catalog) Entries() []Entry {
	return c.content.Entries
}

// Name returns the name of the catalog
func (c *Catalog) Name() string {
	return c.content.Name
}

// Updated returns the update time for catalog
func (c *Catalog) Updated() time.Time {
	return c.content.Date
}
