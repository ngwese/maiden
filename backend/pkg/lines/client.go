package lines

import (
	"fmt"
	"io/ioutil"
	"net/http"
)

// Client struct to represent a connection to the lines Discourse API
type Client struct {
	client   *http.Client
	Endpoint string
}

// NewClient builds a new HTTP client
func NewClient(endpoint string) *Client {
	client := &http.Client{}
	return &Client{
		client:   client,
		Endpoint: endpoint,
	}
}

// Get a resource
func (c *Client) Get(resource string) ([]byte, int, error) {
	// build request
	url := fmt.Sprintf("%s%s", c.Endpoint, resource)
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, 0, err
	}

	// perform request
	resp, err := c.client.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return nil, 0, err
	}
	// log.Printf("body %v", body)

	return body, resp.StatusCode, nil
}
