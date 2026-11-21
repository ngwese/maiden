package lines

import (
	"encoding/json"
	"fmt"
	"net/url"
	"regexp"
	"strings"
)

// Category captures a subset of the properties of a Discourse category
type Category struct {
	ID   int    `json:"id"`
	Name string `json:"name"`
}

// CategoryList captures a subset of the properties for a Discourse category listing
type categoryList struct {
	Categories []Category `json:"categories"`
}

type getCategoryResponse struct {
	CategoryList categoryList `json:"category_list"`
}

// Topic represents a Topic resource from the Discourse API
type Topic struct {
	ID         int      `json:"id"`
	Title      string   `json:"title"`
	FancyTitle string   `json:"fancy_title"`
	PostsCount int      `json:"posts_count"`
	CategoryID int      `json:"category_id"`
	Tags       []string `json:"tags"`
	IsVisible  bool     `json:"visible"`
	IsArchived bool     `json:"archived"`
}

type topicList struct {
	Topics []Topic `json:"topics"`
}

type getCategoryTopicsResponse struct {
	TopicList topicList `json:"topic_list"`
}

type CreatedBy struct {
	AvatarTemplate string `json:"avatar_template"`
	ID             int    `json:"id"`
	Name           string `json:"name"`
	Username       string `json:"username"`
}

type Link struct {
	IsAttachment bool   `json:"attachment"`
	Domain       string `json:"domain"`
	Title        string `json:"title"`
	URL          string `json:"url"`
	UserID       int    `json:"user_id"`
}

type Details struct {
	CreatedBy CreatedBy `json:"created_by"`
	Links     []Link    `json:"links"`
}

type getTopicPostsResponse struct {
	Details Details `json:"details"`
}

var namePattern *regexp.Regexp

func init() {
	namePattern = regexp.MustCompile(`^\s*([\w\s]+)`)
}

func GetCategories(client *Client) ([]Category, error) {
	body, _, err := client.Get("/categories.json")
	if err != nil {
		return nil, err
	}

	var content getCategoryResponse
	err = json.Unmarshal(body, &content)
	if err != nil {
		return nil, err
	}
	// log.Printf("cl: %v", content)
	return content.CategoryList.Categories, nil
}

func LookupCategoryID(name string, categories []Category) (int, bool) {
	for _, c := range categories {
		if c.Name == name {
			return c.ID, true
		}
	}
	return 0, false
}

func GetTopics(client *Client, categoryID int) ([]Topic, error) {
	url := fmt.Sprintf("/c/%d.json", categoryID)
	body, _, err := client.Get(url)
	if err != nil {
		return nil, err
	}

	var content getCategoryTopicsResponse
	err = json.Unmarshal(body, &content)
	if err != nil {
		return nil, err
	}

	return content.TopicList.Topics, nil
}

func TopicHasTag(t *Topic, tag string) bool {
	for _, n := range t.Tags {
		if n == tag {
			return true
		}
	}
	return false
}

func GetTopicDetails(client *Client, topicID int) (*Details, error) {
	url := fmt.Sprintf("/t/%d.json", topicID)
	body, _, err := client.Get(url)
	if err != nil {
		return nil, err
	}

	var content getTopicPostsResponse
	err = json.Unmarshal(body, &content)
	if err != nil {
		return nil, err
	}

	return &content.Details, nil
}

// ProjectNameFromTopicTitle attempts to determine the project name from topic title
func ProjectNameFromTopicTitle(title string) string {
	n := title
	m := namePattern.FindString(title)
	if m != "" {
		n = m
	}
	n = strings.TrimSpace(strings.ToLower(n))
	return strings.Replace(n, " ", "_", -1)
}

// GuessProjectURLFromLinks attempts to find a URL for the project among the links posted in the topic
func GuessProjectURLFromLinks(links []Link) (string, bool) {
	// FIXME: this is really lame logic and not very robust
	// TODO: look at link titles for semver info and use that to sort
	// TODO: deal with conflicting links like doc link in `takt` topic

	// priority order:
	// (1) git repos (github.com, gitlab.com, bitbucket.org)
	// (2) zip archive attachments on lines
	// (3) zip archive somewhere else

	var candidates [3]string

	for _, l := range links {
		if strings.HasSuffix(l.URL, ".git") {
			return l.URL, true
		}
		if strings.HasSuffix(l.URL, ".zip") {
			if l.IsAttachment {
				candidates[1] = l.URL
			} else {
				candidates[2] = l.URL
			}
			continue
		}
		if l.Domain == "github.com" || l.Domain == "gitlab.com" || l.Domain == "bitbucket.org" {
			return extractRepoURL(l.URL), true
		}
	}
	for _, u := range candidates {
		if u != "" {
			return u, true
		}
	}
	return "", false
}

func extractRepoURL(rawURL string) string {
	u, err := url.Parse(rawURL)
	if err != nil {
		return rawURL
	}
	// log.Printf("extract path: %s", u.Path)
	parts := strings.Split(u.Path, "/")
	// log.Printf("parts: %+v", parts[:3])
	repoPath := strings.Join(parts[:3], "/")
	// log.Printf("repo path: %s", repoPath)
	u.Path = repoPath
	return u.String()
}
