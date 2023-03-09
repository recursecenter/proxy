package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/google/uuid"
	"golang.org/x/sync/errgroup"
)

type syncMap struct {
	m     map[string]string
	mutex sync.Mutex
}

func (sm *syncMap) lookup(key string) (string, bool) {
	sm.mutex.Lock()
	defer sm.mutex.Unlock()

	if sm.m == nil {
		return "", false
	}

	s, ok := sm.m[key]
	return s, ok
}

func (sm *syncMap) replace(m map[string]string) {
	sm.mutex.Lock()
	defer sm.mutex.Unlock()

	sm.m = m
}

func fetchDomains(ctx context.Context, url string) (map[string]string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}

	client := http.Client{}

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("received %d when fetching %s", resp.StatusCode, url)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	// parse body as json. The schema is an array of arrays, each inner array has 2 elements, both of them are strings
	var domains [][]string
	err = json.Unmarshal(body, &domains)
	if err != nil {
		return nil, err
	}

	mapping := make(map[string]string)
	for _, domain := range domains {
		mapping[domain[0]] = domain[1]
	}

	return mapping, nil
}

func proxy(w http.ResponseWriter, r *http.Request, mapping *syncMap, domain string, forceTLS bool) {
	requestID := r.Header.Get("X-Request-ID")
	if requestID == "" {
		id, err := uuid.NewRandom()
		if err == nil {
			requestID = id.String()
		} else {
			requestID = "unknown"
		}
	}

	// r.TLS is always nil right now because Proxy doesn't support TLS natively.
	// Here for future-proofing only.
	isTLS := r.TLS != nil || r.Header.Get("X-Forwarded-Proto") == "https"
	var scheme string
	if isTLS {
		scheme = "https://"
	} else {
		scheme = "http://"
	}

	originalURL := scheme + r.Host + r.URL.String()

	if forceTLS && !isTLS {
		log.Printf("request_id=%s %s %s; 301 Moved Permanently; redirect http -> https", requestID, r.Method, originalURL)
		http.Redirect(w, r, "https://"+r.Host+r.URL.String(), http.StatusMovedPermanently)
		return
	}

	subdomain := strings.Split(r.Host, ".")[0]

	// If domain is example.com, then we want to proxy requests to
	// foo.example.com, but not foo.bar.example.com.
	if r.Host != subdomain+"."+domain {
		log.Printf("request_id=%s %s %s; 502 Bad Gateway; error: invalid host: %q must be a subdomain of %q", requestID, r.Method, originalURL, r.Host, domain)
		w.WriteHeader(http.StatusBadGateway)
		if _, err := w.Write([]byte("502 Bad Gateway\n")); err != nil {
			log.Printf("request_id=%s %s %s; error: failed to write 502 response (invalid subdomain): %v", requestID, r.Method, originalURL, err)
		}
		return
	}

	target, ok := mapping.lookup(subdomain)
	if !ok {
		log.Printf("request_id=%s %s %s; 404 Not Found; warning: unknown host: %s", requestID, r.Method, originalURL, r.Host)
		w.WriteHeader(http.StatusNotFound)
		if _, err := w.Write([]byte("404 Not Found\n")); err != nil {
			log.Printf("request_id=%s %s %s; error: failed to write 404 response: %v", requestID, r.Method, originalURL, err)
		}
		return
	}

	u, err := url.Parse(target)
	if err != nil {
		log.Printf("request_id=%s %s %s; 502 Bad Gateway; error: invalid url: %v", requestID, r.Method, originalURL, err)
		w.WriteHeader(http.StatusBadGateway)
		if _, err := w.Write([]byte("502 Bad Gateway\n")); err != nil {
			log.Printf("request_id=%s %s %s; error: failed to write 502 response (invalid url): %v", requestID, r.Method, originalURL, err)
		}
		return
	}

	// Probably not great to make a new ReverseProxy for every request
	// but it means we don't have to do the check of the host header
	// twice just to be able to respond with errors in the way that we
	// want to.
	proxy := &httputil.ReverseProxy{
		Rewrite: func(req *httputil.ProxyRequest) {
			req.SetURL(u)
			req.SetXForwarded()

			// Rewrite() docs say:
			//
			//   Unparsable query parameters are removed from the
			//   outbound request before Rewrite is called.
			//   The Rewrite function may copy the inbound URL's
			//   RawQuery to the outbound URL to preserve the original
			//   parameter string. Note that this can lead to security
			//   issues if the proxy's interpretation of query parameters
			//   does not match that of the downstream server.
			//
			// We don't interpret query parameters at all, so let's just pass them
			// on umodified for maximum compatibility. This is the security issue:
			// https://www.oxeye.io/blog/golang-parameter-smuggling-attack. I don't
			// believe it applies to our usecase.
			req.Out.URL.RawQuery = req.In.URL.RawQuery
		},
		ModifyResponse: func(resp *http.Response) error {
			resp.Header.Set("Server", "Proxy/2.0")
			log.Printf("request_id=%s %s %s -> %s; %s", requestID, r.Method, originalURL, resp.Request.URL, resp.Status)
			return nil
		},
	}

	proxy.ServeHTTP(w, r)
}

func getenv(key, fallback string) string {
	value, ok := os.LookupEnv(key)
	if !ok {
		return fallback
	}

	return value
}

func mustGetenv(key string) string {
	value, ok := os.LookupEnv(key)
	if !ok {
		log.Fatalf("error: %s not set", key)
	}

	return value
}

// Returns the value of the environment variable as a bool.
// Panics if the environment variable is set but fails to parse.
func mustGetenvBool(key string, fallback bool) bool {
	value, ok := os.LookupEnv(key)
	if !ok {
		return fallback
	}

	b, err := strconv.ParseBool(value)
	if err != nil {
		log.Fatalf("error: %s must be a boolean: %v", key, err)
	}

	return b
}

// Returns the value of the environment variable as a time.Duration in seconds.
// Panics if the environment variable is set but fails to parse.
func mustGetenvDuration(key string, fallback time.Duration) time.Duration {
	value, ok := os.LookupEnv(key)
	if !ok {
		return fallback
	}

	i, err := strconv.Atoi(value)
	if err != nil {
		log.Fatalf("error: %s must be an integer: %v", key, err)
	}

	return time.Duration(i) * time.Second
}

func main() {
	log.Printf("Proxy starting...")

	// Only fails if the file fails to parse, not if it doesn't exist.
	if err := loadDotenv(); err != nil {
		log.Fatalf("error: can't reading .env: %v", err)
	}

	addr := ":" + getenv("PORT", "80")
	domain := mustGetenv("DOMAIN")
	endpoint := mustGetenv("ENDPOINT")
	forceTLS := mustGetenvBool("FORCE_TLS", false)
	readTimeout := mustGetenvDuration("READ_TIMEOUT", 5*time.Second)
	writeTimeout := mustGetenvDuration("WRITE_TIMEOUT", 10*time.Second)
	shutdownTimeout := mustGetenvDuration("SHUTDOWN_TIMEOUT", 10*time.Second)
	refreshInterval := mustGetenvDuration("REFRESH_INTERVAL", 5*time.Second)

	if readTimeout < 1*time.Second {
		log.Fatalf("error: read timeout must be at least 1 second")
	} else if writeTimeout < 1*time.Second {
		log.Fatalf("error: write timeout must be at least 1 second")
	} else if shutdownTimeout < 1*time.Second {
		log.Fatalf("error: shutdown timeout must be at least 1 second")
	} else if refreshInterval < 1*time.Second {
		log.Fatalf("error: refresh interval must be at least 1 second")
	}

	log.Printf("*     read timeout: %s", readTimeout)
	log.Printf("*    write timeout: %s", writeTimeout)
	log.Printf("* shutdown timeout: %s", shutdownTimeout)
	log.Printf("* refresh interval: %s", refreshInterval)
	log.Printf("*           domain: %s", domain)
	log.Printf("*         endpoint: %s", endpoint)
	log.Printf("*        force tls: %t", forceTLS)
	log.Printf("* Listening on http://0.0.0.0%s", addr)
	log.Printf("* Listening on http://[::]%s", addr)

	ctx, _ := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	g, ctx := errgroup.WithContext(ctx)

	mapping := &syncMap{}

	mux := http.NewServeMux()

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		proxy(w, r, mapping, domain, forceTLS)
	})

	server := &http.Server{
		Addr:         addr,
		ReadTimeout:  readTimeout,
		WriteTimeout: writeTimeout,
		Handler:      mux,
	}

	// Fetch the domain every refereshInterval
	g.Go(func() error {
		for {
			m, err := fetchDomains(ctx, endpoint)
			if err != nil {
				log.Printf("error: couldn't fetch domains endpoint: %v", err)
			} else {
				mapping.replace(m)
			}

			select {
			case <-ctx.Done():
				return nil
			case <-time.After(refreshInterval):
			}
		}
	})

	// Shutdown the server when we receive a SIGINT or SIGTERM
	g.Go(func() error {
		<-ctx.Done()

		log.Println("Shutting down...")

		shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
		defer cancel()
		return server.Shutdown(shutdownCtx)
	})

	// Start the server
	g.Go(func() error {
		err := server.ListenAndServe()
		if err != nil && err != http.ErrServerClosed {
			return err
		}

		return nil
	})

	if err := g.Wait(); err != nil {
		log.Fatalf("error: %v", err)
	}

	log.Println("Proxy stopped")
}
