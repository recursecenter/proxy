package dotenv

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"unicode"
)

type scanner struct {
	io.RuneScanner
	comment bool
}

func (s *scanner) readSpace() (bool, error) {
	r, _, err := s.ReadRune()
	if err != nil {
		return false, err
	}

	if s.comment && (r == '\n' || r == '\r') {
		s.comment = false
		return true, nil
	} else if s.comment {
		return true, nil
	} else if r == '#' {
		s.comment = true
		return true, nil
	} else if unicode.IsSpace(r) {
		return true, nil
	} else if err := s.UnreadRune(); err != nil {
		return false, err
	} else {
		return false, nil
	}
}

func (s *scanner) readAllSpace() error {
	for {
		skip, err := s.readSpace()
		if err != nil {
			return err
		}

		if !skip {
			return nil
		}
	}
}

func (s *scanner) expect(r rune) error {
	r2, _, err := s.ReadRune()
	if err != nil {
		return err
	}

	if r2 != r {
		return fmt.Errorf("expected %q, got %q", r, r2)
	}

	return nil
}

func (s *scanner) readLetter() (rune, bool, error) {
	r, _, err := s.ReadRune()
	if err != nil {
		return 0, false, err
	}

	if unicode.IsLetter(r) {
		return r, true, nil
	}

	if err := s.UnreadRune(); err != nil {
		return 0, false, err
	}

	return r, false, nil
}

func (s *scanner) expectLetter() (rune, error) {
	r, ok, err := s.readLetter()
	if err != nil {
		return 0, err
	}

	if !ok {
		return 0, fmt.Errorf("expected letter, got %q", r)
	}

	return r, nil
}

func (s *scanner) readNameRune() (rune, bool, error) {
	r, _, err := s.ReadRune()
	if err != nil {
		return 0, false, err
	}

	if unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_' {
		return r, true, nil
	}

	if err := s.UnreadRune(); err != nil {
		return 0, false, err
	}

	return r, false, nil
}

func (s *scanner) readName() (string, error) {
	var runes []rune

	r, err := s.expectLetter()
	if err != nil {
		return "", err
	}

	runes = append(runes, r)

	for {
		r, ok, err := s.readNameRune()
		if err == io.EOF {
			break
		} else if err != nil {
			return "", err
		}

		if !ok {
			break
		}

		runes = append(runes, r)
	}

	return string(runes), nil
}

func (s *scanner) readLineWithDelim(delim rune) (string, error) {
	var runes []rune

	for {
		r, _, err := s.ReadRune()
		if err == io.EOF {
			return "", fmt.Errorf("unexpected EOF")
		} else if err != nil {
			return "", err
		}

		if r == '\n' {
			return "", fmt.Errorf("unexpected newline")
		} else if r == '\r' {
			return "", fmt.Errorf("unexpected carriage return")
		} else if r == delim {
			break
		}

		runes = append(runes, r)
	}

	return string(runes), nil
}

func (s *scanner) readValue() (string, error) {
	r, _, err := s.ReadRune()
	if err != nil {
		return "", err
	}

	if r == '"' || r == '\'' {
		return s.readLineWithDelim(r)
	}

	var runes []rune
	runes = append(runes, r)

	for {
		r, _, err := s.ReadRune()
		if err == io.EOF {
			break
		} else if err != nil {
			return "", err
		}

		if unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_' {
			runes = append(runes, r)
			continue
		}

		if err := s.UnreadRune(); err != nil {
			return "", err
		}

		break
	}

	return string(runes), nil
}

func parse(r io.Reader) (map[string]string, error) {
	env := make(map[string]string)
	s := &scanner{RuneScanner: bufio.NewReader(r)}

	err := s.readAllSpace()
	if err == io.EOF {
		return env, nil
	} else if err != nil {
		return nil, err
	}

	for {
		name, err := s.readName()
		if err != nil {
			return nil, err
		}

		err = s.expect('=')
		if err != nil {
			return nil, err
		}

		value, err := s.readValue()
		if err != nil {
			return nil, err
		}

		env[name] = value

		err = s.readAllSpace()
		if err == io.EOF {
			break
		} else if err != nil {
			return nil, err
		}
	}

	return env, nil
}

func Load() error {
	stat, err := os.Stat(".env")
	if err != nil && os.IsNotExist(err) {
		return nil
	} else if err != nil {
		return err
	}

	if !stat.Mode().IsRegular() {
		return fmt.Errorf("not a regular file: .env")
	}

	f, err := os.Open(".env")
	if err != nil {
		return err
	}
	defer f.Close()

	env, err := parse(f)
	if err != nil {
		return err
	}

	for key, value := range env {
		fmt.Printf("! %s=%s\n", key, value)
		if err := os.Setenv(key, value); err != nil {
			return err
		}
	}

	return nil
}
