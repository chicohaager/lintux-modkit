// Package webmod runs the web backend of a ZimaOS module: the frame every
// Lintux module with a dashboard tile repeats (cron, zbackup, modmanager).
//
//   - restarts the module's own daemons that still run the binary of a
//     replaced image (Options.Restart, see the stale package): zpkg starts
//     the web backend again on every module update, the daemons it does not,
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
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/chicohaager/lintux-modkit/appdata"
	"github.com/chicohaager/lintux-modkit/auth"
	"github.com/chicohaager/lintux-modkit/gateway"
	"github.com/chicohaager/lintux-modkit/httpx"
	"github.com/chicohaager/lintux-modkit/stale"
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
	// DataDirs are the module's directories under /DATA/AppData. Run checks them
	// with appdata.Secure before anything else and does not start when one cannot
	// be trusted (a symlink, not root's, writable by others): that directory is
	// 0777 without the sticky bit on ZimaOS 1.8, anyone writing there can swap it.
	DataDirs []string
	// Restart lists the units whose binary the module ships, e.g.
	// "nebula.service": each one still running an older binary is restarted
	// at start (stale.Restart). Template instances need their full names.
	Restart []string
	// API builds the API handler. verify wraps a handler with the session
	// token check; <Route>/health is served by webmod without it.
	API func(verify func(http.Handler) http.Handler) http.Handler
}

// selfExe is the running program, binaryTTL how long a file hash is reused;
// tests change both.
var (
	selfExe   = "/proc/self/exe"
	binaryTTL = 30 * time.Second
)

// binaryCheck compares the running program with the file at Options.Binary.
// After a module update without a restart the process runs the old program
// while the file is new: `zpkg install --force` does not restart the service
// (measured on ZimaOS 1.8.0, 27.10.2026). /proc/self/exe keeps the old program.
type binaryCheck struct {
	path    string
	once    sync.Once
	running []byte
	mu      sync.Mutex
	hashed  time.Time
	file    []byte
	logged  bool
}

// state is "current", "replaced" (the file differs from the running program:
// restart the service) or "unknown" (no Binary set, or a file cannot be read).
func (b *binaryCheck) state(service string) string {
	if b.path == "" {
		return "unknown"
	}
	b.once.Do(func() { b.running, _ = sum(selfExe) })
	if b.running == nil {
		return "unknown"
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	// No stat-based cache: after `zpkg install --force` of another image the file had the
	// same size, mtime, ctime and inode (overlayfs over squashfs, mtimes from the commit;
	// measured on ZimaOS 1.8.0, 27.10.2026) but other bytes. The hash is reused for binaryTTL.
	if b.file == nil || time.Since(b.hashed) >= binaryTTL {
		f, err := sum(b.path)
		if err != nil {
			b.file = nil
			return "unknown"
		}
		b.file, b.hashed = f, time.Now()
	}
	if bytes.Equal(b.file, b.running) {
		return "current"
	}
	if !b.logged {
		log.Printf("[%s] WARNING: %s was replaced since this process started; restart %s to run it", service, b.path, service)
		b.logged = true
	}
	return "replaced"
}

func sum(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return nil, err
	}
	return h.Sum(nil), nil
}

// Handler composes health, API, CSRF and the static UI. Exported for tests.
// GET <Route>/health answers {"status":"ok","version":…,"binary":"current|replaced|unknown"}.
func Handler(o Options, verify func(http.Handler) http.Handler, staticDir string) http.Handler {
	mux := http.NewServeMux()
	bin := &binaryCheck{path: o.Binary}
	mux.HandleFunc(o.Route+"/health", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			httpx.MethodNotAllowed(w)
			return
		}
		httpx.WriteJSON(w, http.StatusOK, map[string]string{"status": "ok", "version": o.Version, "binary": bin.state(o.Service)})
	})
	mux.Handle(o.Route+"/", o.API(verify))
	return httpx.Static("/modules/"+o.Name+"/", staticDir, httpx.CSRF(mux))
}

// Run serves the module until SIGTERM. The environment switches
// <SERVICE>_DISABLE_AUTH=1 and <SERVICE>_STATIC_DIR exist for development;
// the shipped unit sets neither.
func Run(o Options) {
	log.Printf("[%s] starting v%s", o.Service, o.Version)
	if err := secureDataDirs(o.DataDirs); err != nil {
		log.Fatalf("[%s] %v", o.Service, err)
	}
	if len(o.Restart) > 0 {
		for _, u := range stale.Restart(context.Background(), stale.Options{Units: o.Restart}) {
			log.Printf("[%s] restarted %s: it ran the binary of the replaced module", o.Service, u)
		}
	}
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

// secureDataDirs runs appdata.Secure on each data directory (ZIMAOS-KNOWLEDGE §79.11).
func secureDataDirs(dirs []string) error {
	for _, d := range dirs {
		if err := appdata.Secure(d); err != nil {
			return err
		}
	}
	return nil
}
