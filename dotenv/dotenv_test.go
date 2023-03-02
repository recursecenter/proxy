package dotenv

import (
	"testing"
)

func TestSimple(t *testing.T) {
	s := "FOO=bar"

	env, err := parse(s)
	if err != nil {
		t.Fatal(err)
	}

	if len(env) != 1 {
		t.Fatalf("expected 1 env var, got %d", len(env))
	}

	if env["FOO"] != "bar" {
		t.Fatalf("expected FOO=bar, got %s", env["FOO"])
	}
}

func TestMulti(t *testing.T) {
	s := "FOO=bar\nBAZ=qux"

	env, err := parse(s)
	if err != nil {
		t.Fatal(err)
	}

	if len(env) != 2 {
		t.Fatalf("expected 2 env vars, got %d", len(env))
	}

	if env["FOO"] != "bar" {
		t.Fatalf("expected FOO=bar, got %s", env["FOO"])
	}

	if env["BAZ"] != "qux" {
		t.Fatalf("expected BAZ=qux, got %s", env["BAZ"])
	}
}

func TestEmpty(t *testing.T) {
	s := ""

	env, err := parse(s)
	if err != nil {
		t.Fatal(err)
	}

	if len(env) != 0 {
		t.Fatalf("expected 0 env vars, got %d", len(env))
	}
}

func TestWhiteSpace(t *testing.T) {
	s := "  \n FOO=bar   \n"

	env, err := parse(s)
	if err != nil {
		t.Fatal(err)
	}

	if len(env) != 1 {
		t.Fatalf("expected 1 env var, got %d", len(env))
	}

	if env["FOO"] != "bar" {
		t.Fatalf("expected FOO=bar, got %s", env["FOO"])
	}
}

func TestQuote(t *testing.T) {
	s := "ONE='two \" three'  \n  FOUR=\"five ' six\""

	env, err := parse(s)
	if err != nil {
		t.Fatal(err)
	}

	if len(env) != 2 {
		t.Fatalf("expected 2 env vars, got %d", len(env))
	}

	if env["ONE"] != "two \" three" {
		t.Fatalf("expected ONE='two \" three', got %s", env["ONE"])
	}

	if env["FOUR"] != "five ' six" {
		t.Fatalf("expected FOUR=\"five ' six\", got %s", env["FOUR"])
	}
}

func TestComment(t *testing.T) {
	s := "# FOO=bar"

	env, err := parse(s)
	if err != nil {
		t.Fatal(err)
	}

	if len(env) != 0 {
		t.Fatalf("expected 0 env vars, got %d", len(env))
	}

	s = "FOO=bar # set FOO to bar"

	env, err = parse(s)
	if err != nil {
		t.Fatal(err)
	}

	if len(env) != 1 {
		t.Fatalf("expected 1 env var, got %d", len(env))
	}

	if env["FOO"] != "bar" {
		t.Fatalf("expected FOO=bar, got %s", env["FOO"])
	}

	s = "FOO=bar # set FOO to bar\nBAZ=qux\n"

	env, err = parse(s)
	if err != nil {
		t.Fatal(err)
	}

	if len(env) != 2 {
		t.Fatalf("expected 2 env vars, got %d", len(env))
	}

	if env["FOO"] != "bar" {
		t.Fatalf("expected FOO=bar, got %s", env["FOO"])
	}
}

func TestBad(t *testing.T) {
	s := "FOO"

	_, err := parse(s)
	if err == nil {
		t.Fatal("expected error")
	}

	s = "FOO=bar\nBAZ"
	_, err = parse(s)
	if err == nil {
		t.Fatal("expected error")
	}

	s = "1FOO=bar"
	_, err = parse(s)
	if err == nil {
		t.Fatal("expected error")
	}

	s = "FOO=bar baz\nBAZ=qux"
	_, err = parse(s)
	if err == nil {
		t.Fatal("expected error")
	}

	s = "FOO BAR=baz qux"
	_, err = parse(s)
	if err == nil {
		t.Fatal("expected error")
	}
}
