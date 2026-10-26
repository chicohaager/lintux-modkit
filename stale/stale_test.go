package stale

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// world is a fake host: units with a main PID, /proc/<pid>/exe as a file
// (the running binary) and the binary the unit names in ExecStart.
type world struct {
	t       *testing.T
	proc    string
	active  map[string]string // unit -> pid ("" = inactive)
	exec    map[string]string // unit -> ExecStart path
	restart []string
}

func newWorld(t *testing.T) *world {
	return &world{t: t, proc: t.TempDir(), active: map[string]string{}, exec: map[string]string{}}
}

// unit adds a running unit: running = the bytes its process executes, current = the bytes at ExecStart.
func (w *world) unit(name, pid, running, current string) {
	dir := filepath.Join(w.proc, pid)
	_ = os.MkdirAll(dir, 0o755)
	_ = os.WriteFile(filepath.Join(dir, "exe"), []byte(running), 0o755)
	bin := filepath.Join(w.t.TempDir(), "bin")
	_ = os.WriteFile(bin, []byte(current), 0o755)
	w.active[name], w.exec[name] = pid, bin
}

func (w *world) systemctl(_ context.Context, args ...string) ([]byte, error) {
	switch {
	case args[0] == "show" && args[1] == "-p" && args[2] == "MainPID":
		if p := w.active[args[4]]; p != "" {
			return []byte(p + "\n"), nil
		}
		return []byte("0\n"), nil
	case args[0] == "show" && args[1] == "-p" && args[2] == "ExecStart":
		// systemd's form, measured on ZimaOS 1.8.0
		return []byte("{ path=" + w.exec[args[4]] + " ; argv[]=" + w.exec[args[4]] + " -x ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }\n"), nil
	case args[0] == "restart":
		w.restart = append(w.restart, args[1])
		return nil, nil
	}
	w.t.Fatalf("unexpected systemctl %v", args)
	return nil, nil
}

func (w *world) opts(units ...string) Options {
	return Options{Units: units, Proc: w.proc, Systemctl: w.systemctl}
}

func TestOnlyAUnitRunningOtherBytesIsRestarted(t *testing.T) {
	w := newWorld(t)
	w.unit("nebula.service", "100", "old nebula", "new nebula")        // module update replaced the binary
	w.unit("node-exporter.service", "200", "same bytes", "same bytes") // another module's update re-mounted /usr only
	got := Restart(context.Background(), w.opts("nebula.service", "node-exporter.service", "stopped.service"))
	if strings.Join(w.restart, " ") != "nebula.service" || strings.Join(got, " ") != "nebula.service" {
		t.Fatalf("restarted %v (returned %v), want only nebula.service", w.restart, got)
	}
}

func TestNothingIsRestartedWhenItCannotBeCompared(t *testing.T) {
	w := newWorld(t)
	w.unit("gone.service", "300", "bytes", "bytes")
	w.exec["gone.service"] = filepath.Join(t.TempDir(), "missing") // ExecStart binary unreadable
	w.active["nopid.service"] = "400"                              // no /proc/400/exe
	w.exec["nopid.service"] = w.exec["gone.service"]
	Restart(context.Background(), w.opts("gone.service", "nopid.service"))
	if len(w.restart) != 0 {
		t.Fatalf("restarted %v without a comparison", w.restart)
	}
}

func TestExecStartPath(t *testing.T) {
	for in, want := range map[string]string{
		"{ path=/usr/bin/nebula ; argv[]=/usr/bin/nebula -config /DATA/x.yml ; ignore_errors=no }": "/usr/bin/nebula",
		"{ path=/usr/libexec/pangolin/pangolin ; argv[]=/usr/libexec/pangolin/pangolin up site }":  "/usr/libexec/pangolin/pangolin",
		// measured on ZimaOS 1.8.0: an argument that contains "path=" as well
		"{ path=/usr/bin/smartctl_exporter ; argv[]=/usr/bin/smartctl_exporter --web.listen-address=:9633 --smartctl.path=/usr/sbin/smartctl ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }": "/usr/bin/smartctl_exporter",
		"": "",
	} {
		if got := execPath(in); got != want {
			t.Errorf("execPath(%q) = %q, want %q", in, got, want)
		}
	}
}
