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

	"github.com/recursecenter/proxy/dotenv"
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

	// read bytes from resp as json
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

func proxy(w http.ResponseWriter, r *http.Request, mapping *syncMap, domain string) {
	subdomain := strings.Split(r.Host, ".")[0]

	// If domain is example.com, then we want to proxy requests to
	// foo.example.com, but not foo.bar.example.com.
	if r.Host != subdomain+"."+domain {
		log.Printf("[%s] %s %s; error: invalid host: %q must be a subdomain of %q", r.Host, r.Method, r.URL, r.Host, domain)
		w.WriteHeader(http.StatusBadGateway)
		w.Write([]byte("502 Bad Gateway\n"))
		return
	}

	target, ok := mapping.lookup(subdomain)
	if !ok {
		log.Printf("[%s] %s %s; error: unknown host: %s", r.Host, r.Method, r.URL, r.Host)
		w.WriteHeader(http.StatusNotFound)
		w.Write([]byte("404 Not Found\n"))
		return
	}

	u, err := url.Parse(target)
	if err != nil {
		log.Printf("[%s] %s %s; error: invalid url: %v", r.Host, r.Method, r.URL, err)
		w.WriteHeader(http.StatusBadGateway)
		w.Write([]byte("502 Bad Gateway\n"))
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
			log.Printf("[%s] %s %s -> %s; %s", r.Host, r.Method, r.URL, resp.Request.URL, resp.Status)
			return nil
		},
	}

	proxy.ServeHTTP(w, r)
}

func mustGetenv(key string) string {
	value, ok := os.LookupEnv(key)
	if !ok {
		log.Fatalf("error: %s not set", key)
	}

	return value
}

func getenvInt(key string, fallback int) (int, error) {
	value, ok := os.LookupEnv(key)
	if !ok {
		return fallback, nil
	}

	i, err := strconv.Atoi(value)
	if err != nil {
		return 0, fmt.Errorf("%s must be an integer: %v", key, err)
	} else if i < 1 {
		return 0, fmt.Errorf("%s must be at least 1: %v", key, err)
	}

	return i, nil
}

func loadConfig() (addr, domain, endpoint string, refreshInterval, shutdownTimeout time.Duration) {
	addr = ":" + mustGetenv("PORT")
	domain = mustGetenv("PROXY_DOMAIN")
	endpoint = mustGetenv("PROXY_ENDPOINT")

	i, err := getenvInt("PROXY_REFRESH_INTERVAL", 5)
	if err != nil {
		log.Fatalf("error: %v", err)
	}

	refreshInterval = time.Duration(i) * time.Second

	i, err = getenvInt("PROXY_SHUTDOWN_TIMEOUT", 10)
	if err != nil {
		log.Fatalf("error: %v", err)
	}

	shutdownTimeout = time.Duration(i) * time.Second

	return addr, domain, endpoint, refreshInterval, shutdownTimeout
}

func main() {
	log.Printf("Proxy starting...")

	// Only fails if the file fails to parse, not if it doesn't exist.
	if err := dotenv.Load(); err != nil {
		log.Fatalf("error reading .env: %v", err)
	}

	addr, domain, endpoint, refreshInterval, shutdownTimeout := loadConfig()
	log.Printf("* refresh interval: %s", refreshInterval)
	log.Printf("* shutdown timeout: %s", shutdownTimeout)
	log.Printf("*         endpoint: %s", endpoint)
	log.Printf("*           domain: %s", domain)
	log.Println()
	log.Printf("Listening on %s", addr)

	ctx, _ := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	g, ctx := errgroup.WithContext(ctx)

	mapping := &syncMap{}

	server := &http.Server{
		Addr: addr,
	}
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		proxy(w, r, mapping, domain)
	})

	// Fetch the domain every refereshInterval
	g.Go(func() error {
		for {
			select {
			case <-ctx.Done():
				return nil
			case <-time.After(refreshInterval):
				m, err := fetchDomains(ctx, endpoint)
				if err != nil {
					log.Printf("error fetching domains: %v", err)
					continue
				}

				mapping.replace(m)
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
