package ui

import (
	"embed"
	"net/http"
)

//go:embed index.html
var assets embed.FS

// Handler serves the dashboard from the controller binary.
func Handler() http.Handler { return http.FileServer(http.FS(assets)) }
