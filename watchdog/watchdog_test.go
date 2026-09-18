package watchdog

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInstallWritesUnitsOnceAndRewritesOnChange(t *testing.T) {
	dir := t.TempDir()
	var calls []string
	opts := Options{Service: "cron", Binary: "/usr/bin/cron", UnitDir: dir,
		Systemctl: func(args ...string) error { calls = append(calls, strings.Join(args, " ")); return nil }}

	if err := Install(opts); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"cron-watchdog.service", "cron-watchdog.timer", "cron-refresh.path", "cron-refresh.service"} {
		if _, err := os.Stat(filepath.Join(dir, name)); err != nil {
			t.Errorf("%s not written: %v", name, err)
		}
	}
	if len(calls) != 3 || calls[0] != "daemon-reload" || calls[1] != "enable --now cron-watchdog.timer" {
		t.Fatalf("systemctl calls = %v", calls)
	}

	// unchanged content: no systemctl at all
	calls = nil
	if err := Install(opts); err != nil {
		t.Fatal(err)
	}
	if len(calls) != 0 {
		t.Fatalf("second install with identical units called systemctl: %v", calls)
	}

	// changed option: rewritten and reloaded
	opts.BootDelaySec = 45
	if err := Install(opts); err != nil {
		t.Fatal(err)
	}
	timer, _ := os.ReadFile(filepath.Join(dir, "cron-watchdog.timer"))
	if !strings.Contains(string(timer), "OnBootSec=45") || len(calls) == 0 {
		t.Fatalf("timer not rewritten (%q) or systemd not reloaded (%v)", timer, calls)
	}
}

func TestUnitsNameTheService(t *testing.T) {
	u := Units(Options{Service: "zbackup", Binary: "/usr/bin/zbackupd", BootDelaySec: 15})
	if !strings.Contains(u["zbackup-refresh.path"], "PathChanged=/usr/bin/zbackupd") {
		t.Error("refresh path does not watch the binary")
	}
	if !strings.Contains(u["zbackup-watchdog.service"], "systemctl start zbackup.service") {
		t.Error("watchdog does not start the service")
	}
}

func TestInstallRejectsMissingNames(t *testing.T) {
	if err := Install(Options{UnitDir: t.TempDir()}); err == nil {
		t.Fatal("expected an error without Service/Binary")
	}
}
