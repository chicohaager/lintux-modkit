// Package webmod runs the web backend of a ZimaOS module: the frame every
// Lintux module with a dashboard tile repeats (cron, zbackup, modmanager).
//
//   - installs the boot watchdog for its own service (sysext units are not
//     started at boot, see the watchdog package),
//   - listens on a random loopback port and registers the route prefix with
//     the ZimaOS gateway, retrying for two minutes (the gateway needs ~45 s
//     after boot and a route posted before it listens is lost — measured for
//     cron on 1.7.1),
//   - verifies the ZimaOS session token on every API route (auth), rejects
//     cross-origin state changes (httpx.CSRF) and serves the UI files,
//   - shuts down cleanly on SIGTERM.
package webmod

import (
	"context"
	"errors"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/chicohaager/lintux-modkit/auth"
	"github.com/chicohaager/lintux-modkit/gateway"
	"github.com/chicohaager/lintux-modkit/httpx"
	"github.com/chicohaager/lintux-modkit/watchdog"
)

// Options names the module.
type Options struct {
	// Name is the module name, e.g. "wireguard": the UI lives under
	// /modules/<Name>/ in /usr/share/casaos/www/modules/<Name>.
	Name string
	// Service is the systemd unit without ".service", e.g. "wireguard-web".
	Service string
	// Binary is the daemon's path, e.g. "/usr/bin/wireguard-web".
	Binary string
	// Route is the gateway prefix the API lives under, e.g. "/wireguard".
	Route string
	// Version is reported by GET <Route>/health.
	Version string
	// API builds the API handler. verify wraps a handler with the session
	// token check; <Route>/health is served by webmod without it.
	API func(verify func(http.Handler) http.Handler) http.Handler
}

// Handler composes health, API, CSRF and the static UI. Exported for tests.
func Handler(o Options, verify func(http.Handler) http.Handler, staticDir string) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc(o.Route+"/health", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			httpx.MethodNotAllowed(w)
			return
		}
		httpx.WriteJSON(w, http.StatusOK, map[string]string{"status": "ok", "version": o.Version})
	})
	mux.Handle(o.Route+"/", o.API(verify))
	return httpx.Static("/modules/"+o.Name+"/", staticDir, httpx.CSRF(mux))
}

// Run serves the module until SIGTERM. The environment switches
// <SERVICE>_DISABLE_AUTH=1 and <SERVICE>_STATIC_DIR exist for development;
// the shipped unit sets neither.
func Run(o Options) {
	log.Printf("[%s] starting v%s", o.Service, o.Version)
	if err := watchdog.Install(watchdog.Options{Service: o.Service, Binary: o.Binary}); err != nil {
		log.Printf("[%s] %v", o.Service, err)
	}
	runtimePath := "/var/run/casaos"
	if p := os.Getenv("CASAOS_RUNTIME_PATH"); p != "" {
		runtimePath = p
	}
	env := envPrefix(o.Service)
	verifier := auth.NewVerifier(auth.JWKSResolver(runtimePath))
	if os.Getenv(env+"_DISABLE_AUTH") == "1" {
		log.Printf("[%s] WARNING: authentication disabled by %s_DISABLE_AUTH", o.Service, env)
		verifier = auth.Disabled()
	}
	staticDir := "/usr/share/casaos/www/modules/" + o.Name
	if d := os.Getenv(env + "_STATIC_DIR"); d != "" {
		staticDir = d
	}

	var lc net.ListenConfig
	listener, err := lc.Listen(context.Background(), "tcp", net.JoinHostPort("127.0.0.1", "0"))
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("[%s] listening on http://%s", o.Service, listener.Addr())
	go registerRoute(o, runtimePath, "http://"+listener.Addr().String())

	srv := &http.Server{
		Handler:           httpx.Logging(o.Service, 1<<20)(Handler(o, verifier.Middleware, staticDir)),
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() {
		ch := make(chan os.Signal, 1)
		signal.Notify(ch, syscall.SIGTERM, syscall.SIGINT)
		log.Printf("[%s] received %v, shutting down", o.Service, <-ch)
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(ctx)
	}()
	if err := srv.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func registerRoute(o Options, runtimePath, target string) {
	for i := 1; i <= 60; i++ {
		err := gateway.Register(context.Background(), runtimePath, o.Route, target, 10*time.Second)
		if err == nil {
			log.Printf("[%s] gateway route registered: %s -> %s", o.Service, o.Route, target)
			return
		}
		log.Printf("[%s] gateway route attempt %d: %v", o.Service, i, err)
		time.Sleep(2 * time.Second)
	}
	log.Printf("[%s] gave up registering the gateway route", o.Service)
}

// envPrefix turns "wireguard-web" into "WIREGUARD_WEB".
func envPrefix(s string) string {
	b := []byte(s)
	for i, c := range b {
		switch {
		case c >= 'a' && c <= 'z':
			b[i] = c - 'a' + 'A'
		case c == '-':
			b[i] = '_'
		}
	}
	return string(b)
}
