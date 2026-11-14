package main

import (
	"os"
	"path/filepath"
	"testing"
)

func withHome(t *testing.T, config string) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if config != "" {
		os.MkdirAll(filepath.Join(home, ".config", "loom-node"), 0o700)
		os.WriteFile(configPath(), []byte(config), 0o600)
	}
}

func TestOneLoomConfigIsStillRead(t *testing.T) {
	withHome(t, `{"url":"https://a.example","token":"ta","shell":"/bin/zsh"}`)
	c, err := loadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if len(c.Looms) != 1 || c.Looms[0] != (loom{"https://a.example", "ta"}) || c.Shell != "/bin/zsh" {
		t.Fatalf("got %+v", c)
	}
}

func TestSeveralLooms(t *testing.T) {
	withHome(t, `{"looms":[{"url":"https://a.example","token":"ta"},{"url":"https://b.example","token":"tb"}]}`)
	c, err := loadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if l, ok := c.find("https://b.example"); !ok || l.Token != "tb" {
		t.Fatalf("got %+v", c)
	}
	if _, ok := c.find("https://c.example"); ok {
		t.Fatal("found a loom the config does not name")
	}
}

func TestNoConfigIsEmptyButNotLoadable(t *testing.T) {
	withHome(t, "")
	if c, err := readConfig(); err != nil || len(c.Looms) != 0 {
		t.Fatalf("got %+v, %v", c, err)
	}
	if _, err := loadConfig(); err == nil {
		t.Fatal("a config naming no loom loaded")
	}
}

func TestWrittenConfigDropsTheOldShape(t *testing.T) {
	withHome(t, `{"url":"https://a.example","token":"ta"}`)
	c, _ := readConfig()
	c.Looms = append(c.Looms, loom{"https://b.example", "tb"})
	if err := writeConfig(*c); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(configPath())
	want := "{\n  \"looms\": [\n    {\n      \"url\": \"https://a.example\",\n      \"token\": \"ta\"\n    },\n" +
		"    {\n      \"url\": \"https://b.example\",\n      \"token\": \"tb\"\n    }\n  ],\n  \"shell\": \"\"\n}\n"
	if string(b) != want {
		t.Fatalf("wrote %s", b)
	}
}
