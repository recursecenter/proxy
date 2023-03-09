package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"regexp"
	"strings"
)

var (
	lineRe = regexp.MustCompile(`^([A-Za-z_][A-Za-z0-9_]*)=(\S.*)$`)

	// bare value (no white space) followed by optional whitespace and optional comment
	bareRe = regexp.MustCompile(`^(\S+)\s*(:?#.*)?$`)

	// quoted strings followed by optional whitespace and optional comment
	singleRe = regexp.MustCompile(`^'([^']*)'\s*(:?#.*)?$`)
	doubleRe = regexp.MustCompile(`^"([^"]*)"\s*(:?#.*)?$`)
)

func parseDotenv(s string) (map[string]string, error) {
	env := make(map[string]string)

	s = strings.ReplaceAll(s, "\r\n", "\n")
	s = strings.ReplaceAll(s, "\r", "\n")

	for _, line := range strings.Split(s, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || line[0] == '#' {
			continue
		}

		m := lineRe.FindStringSubmatch(line)
		if m == nil {
			return nil, fmt.Errorf("invalid line: %q", line)
		}

		name := m[1]
		value := m[2]

		if m := singleRe.FindStringSubmatch(value); m != nil {
			value = m[1]
		} else if m := doubleRe.FindStringSubmatch(value); m != nil {
			value = m[1]
		} else if m := bareRe.FindStringSubmatch(value); m != nil {
			value = m[1]
		} else {
			return nil, fmt.Errorf("invalid line: %q", line)
		}

		env[name] = value
	}

	return env, nil
}

func loadDotenv() error {
	data, err := os.ReadFile(".env")
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	} else if err != nil {
		return err
	}

	env, err := parseDotenv(string(data))
	if err != nil {
		return err
	}

	for key, value := range env {
		if err := os.Setenv(key, value); err != nil {
			return err
		}
	}

	return nil
}
