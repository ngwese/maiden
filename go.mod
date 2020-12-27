module github.com/monome/maiden

go 1.12

require (
	github.com/BurntSushi/toml v0.3.1 // indirect
	github.com/coreos/go-systemd v0.0.0-20181031085051-9002847aa142
	github.com/gin-contrib/sse v0.0.0-20170109093832-22d885f9ecc7 // indirect
	github.com/gin-gonic/gin v0.0.0-20180417025440-6ad7b9c9d382
	github.com/godbus/dbus v0.0.0-20181101234600-2ff6f7ffd60f // indirect
	github.com/google/gofuzz v0.0.0-20170612174753-24818f796faf // indirect
	github.com/hashicorp/go-getter v1.5.1
	github.com/inconshreveable/mousetrap v1.0.0 // indirect
	github.com/json-iterator/go v0.0.0-20180125064802-358cfc39298c // indirect
	github.com/mattn/go-isatty v0.0.4 // indirect
	github.com/monome/maiden/pkg/catalog v0.0.0-00010101000000-000000000000
	github.com/monome/maiden/pkg/dust v0.0.0-00010101000000-000000000000
	github.com/monome/maiden/pkg/lines v0.0.0-00010101000000-000000000000
	github.com/sirupsen/logrus v1.4.1
	github.com/spf13/cobra v0.0.3
	github.com/spf13/viper v1.3.2
	github.com/ugorji/go/codec v0.0.0-20190204201341-e444a5086c43 // indirect
	gopkg.in/go-playground/assert.v1 v1.2.1 // indirect
	gopkg.in/go-playground/validator.v8 v8.18.2 // indirect
)

replace github.com/monome/maiden/pkg/lines => ./pkg/lines

replace github.com/monome/maiden/pkg/catalog => ./pkg/catalog

replace github.com/monome/maiden/pkg/dust => ./pkg/dust
