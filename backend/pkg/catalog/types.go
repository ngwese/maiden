package catalog

// Header describes the file type and schema version for compatibility purposes
type Header struct {
	Version int    `json:"version"`
	Kind    string `json:"kind"`
}
