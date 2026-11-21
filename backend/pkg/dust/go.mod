module github.com/monome/maiden/pkg/dust

go 1.12

require (
	github.com/go-git/go-git/v5 v5.2.0
	github.com/monome/maiden/pkg/catalog v0.0.0
)

replace github.com/monome/maiden/pkg/catalog => ../catalog
