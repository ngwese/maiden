package lines

import (
	"errors"
	"fmt"
	"log"

	"github.com/monome/maiden/pkg/catalog"
)

const linesURL = "https://llllllll.co"

// GatherProjects collects up project information from the Library topic on lines
func GatherProjects(c *catalog.Catalog) error {
	client := NewClient(linesURL)
	categories, err := GetCategories(client)
	if err != nil {
		return err
	}

	libraryCategoryID, found := LookupCategoryID("Library", categories)
	if !found {
		return errors.New("can't find library category id")
	}

	topics, err := GetTopics(client, libraryCategoryID)
	if err != nil {
		return err
	}

	for _, t := range topics {
		if TopicHasTag(&t, "norns") {
			details, err := GetTopicDetails(client, t.ID)
			if details == nil || err != nil {
				log.Printf("\tfailed to get details (%s)", err)
				continue
			}
			discussionURL := fmt.Sprintf("%s/t/%d", linesURL, t.ID)
			author := fmt.Sprintf("%s (%s)", details.CreatedBy.Name, details.CreatedBy.Username)
			url, _ := GuessProjectURLFromLinks(details.Links)
			c.Insert(&catalog.Entry{
				Origin:      "lines",
				ProjectName: ProjectNameFromTopicTitle(t.Title),
				Author:      author,
				URL:         url,
				Discussion:  discussionURL,
			})
		}
	}

	return nil
}
