// Package stale restarts services that still run the binary of a replaced
// module image.
//
// `zpkg remove` + `zpkg install` (a module update) restarts only the services
// in the module JSON — the web backend. A daemon the module ships (nebula,
// node_exporter, the Pangolin tunnel) keeps running the old binary until it
// is restarted (measured on ZimaOS 1.8.0, 2026-10-26). Any `zpkg install`
// re-mounts the merged /usr, so every module process then shows a detached
// path in /proc/<pid>/exe ("/bin/node_exporter" instead of
// "/usr/bin/node_exporter") — also when its own module did not change. The
// path is therefore no sign of an update; the bytes are: a unit is stale when
// the binary its process runs differs from the file its ExecStart names.
//
// The web backend of a module calls Restart at start (webmod.Options.Restart):
// zpkg starts it again on every update of its module.
package stale

import (
	"bytes"
	"context"
	"crypto/sha256"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Options names the units to check.
type Options struct {
	// Units are full unit names whose binary comes from the module, e.g.
	// "nebula.service". Inactive units are left alone.
	Units []string
	// Proc is the proc file system (tests: a directory with <pid>/exe files).
	Proc string
	// Systemctl runs systemctl (tests: a fake).
	Systemctl func(ctx context.Context, args ...string) ([]byte, error)
}

func systemctl(ctx context.Context, args ...string) ([]byte, error) {
	return exec.CommandContext(ctx, "systemctl", args...).Output()
}

// Restart restarts each active unit whose running binary differs from the
// binary its ExecStart names, and returns the units it restarted. A unit that
// cannot be compared (no main PID, unreadable binary) is left running.
func Restart(ctx context.Context, o Options) []string {
	if o.Proc == "" {
		o.Proc = "/proc"
	}
	if o.Systemctl == nil {
		o.Systemctl = systemctl
	}
	var done []string
	for _, u := range o.Units {
		out, err := o.Systemctl(ctx, "show", "-p", "MainPID", "--value", u)
		pid := strings.TrimSpace(string(out))
		if err != nil || pid == "" || pid == "0" {
			continue
		}
		out, err = o.Systemctl(ctx, "show", "-p", "ExecStart", "--value", u)
		bin := execPath(string(out))
		if err != nil || bin == "" {
			continue
		}
		running, err1 := sum(filepath.Join(o.Proc, pid, "exe"))
		current, err2 := sum(bin)
		if err1 != nil || err2 != nil {
			log.Printf("stale: %s not compared: %v %v", u, err1, err2)
			continue
		}
		if bytes.Equal(running, current) {
			continue
		}
		log.Printf("stale: %s (pid %s) runs an older %s: restarting it", u, pid, bin)
		rctx, cancel := context.WithTimeout(ctx, 90*time.Second)
		_, err = o.Systemctl(rctx, "restart", u)
		cancel()
		if err != nil {
			log.Printf("stale: restart %s: %v", u, err)
			continue
		}
		done = append(done, u)
	}
	return done
}

// execPath takes the binary from `systemctl show -p ExecStart --value`:
// "{ path=/usr/bin/nebula ; argv[]=/usr/bin/nebula -config … ; … }".
func execPath(s string) string {
	_, rest, ok := strings.Cut(s, "path=")
	if !ok {
		return ""
	}
	p, _, _ := strings.Cut(rest, " ;")
	return strings.TrimSpace(p)
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
