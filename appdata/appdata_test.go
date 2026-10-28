package appdata

import (
	"errors"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// /DATA/AppData is 0777 without the sticky bit on ZimaOS 1.8 (KB §79.11): anyone
// who can write there renames root's directory and puts their own in its place.
// Secure sets the sticky bit on the parent (then only the owner renames), and
// creates the module's directory 0700.
// tmp is a test directory 0755: t.TempDir follows the umask (002 here: group-writable,
// which Secure rightly refuses as an ancestor).
func tmp(t *testing.T) string {
	d := t.TempDir()
	if err := os.Chmod(d, 0o755); err != nil {
		t.Fatal(err)
	}
	return d
}

func TestSecureSetsTheStickyBitAndCreatesTheDirectory(t *testing.T) {
	parent := filepath.Join(tmp(t), "AppData")
	if err := os.Mkdir(parent, 0o777); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(parent, 0o777); err != nil { // past the umask
		t.Fatal(err)
	}
	dir := filepath.Join(parent, "wireguard")
	if err := Secure(dir); err != nil {
		t.Fatal(err)
	}
	pfi, _ := os.Lstat(parent)
	if pfi.Mode()&os.ModeSticky == 0 {
		t.Fatalf("parent %v: no sticky bit", pfi.Mode())
	}
	fi, err := os.Lstat(dir)
	if err != nil || !fi.IsDir() || fi.Mode().Perm() != 0o700 {
		t.Fatalf("dir %v %v", fi, err)
	}
	// an existing directory stays as it is (a module may keep 0755)
	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := Secure(dir); err != nil {
		t.Fatal(err)
	}
	if fi, _ := os.Lstat(dir); fi.Mode().Perm() != 0o755 {
		t.Fatalf("existing dir changed to %v", fi.Mode())
	}
}

func TestSecureRefusesWhatRootMustNotTrust(t *testing.T) {
	mk := func(t *testing.T) (string, string) {
		parent := filepath.Join(tmp(t), "AppData")
		if err := os.Mkdir(parent, 0o755); err != nil {
			t.Fatal(err)
		}
		return parent, filepath.Join(parent, "nebula")
	}
	t.Run("directory is a symlink", func(t *testing.T) {
		_, dir := mk(t)
		if err := os.Symlink(t.TempDir(), dir); err != nil {
			t.Fatal(err)
		}
		if err := Secure(dir); err == nil || !strings.Contains(err.Error(), "is a symlink") {
			t.Fatalf("err %v", err)
		}
	})
	t.Run("directory others can write", func(t *testing.T) {
		_, dir := mk(t)
		if err := os.Mkdir(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(dir, 0o777); err != nil {
			t.Fatal(err)
		}
		if err := Secure(dir); err == nil || !strings.Contains(err.Error(), "others can write to "+dir) {
			t.Fatalf("err %v", err)
		}
	})
	t.Run("directory of another user", func(t *testing.T) {
		_, dir := mk(t)
		if err := os.Mkdir(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		// the directory belongs to this test's user; pretend root is someone else, the parent still trusted
		owner := trusted
		trusted = func(uid int) bool { return uid == 0 }
		defer func() { trusted = owner }()
		parentOK = func(string) bool { return true }
		defer func() { parentOK = nil }()
		if err := Secure(dir); err == nil || !strings.Contains(err.Error(), dir+" belongs to uid") {
			t.Fatalf("err %v", err)
		}
	})
	t.Run("an ancestor others can write, without sticky bit", func(t *testing.T) {
		top := tmp(t)
		if err := os.Chmod(top, 0o777); err != nil {
			t.Fatal(err)
		}
		parent := filepath.Join(top, "AppData")
		if err := os.Mkdir(parent, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := Secure(filepath.Join(parent, "x")); err == nil || !strings.Contains(err.Error(), top+" (mode") {
			t.Fatalf("err %v, want it to name %s", err, top)
		}
	})
}

// /DATA owned by the login user (uid 999 on nas-main, 2026-10-28) stopped every module
// with this guard. Secure gives exactly /DATA back to root and logs it; nothing else
// is changed. The tests do not run as root: chown is replaced, and "root" is this
// test's user once the fake chown has run.
func TestSecureGivesDataBackToRoot(t *testing.T) {
	self := os.Geteuid()
	type call struct {
		path     string
		uid, gid int
	}
	setup := func(t *testing.T, mode os.FileMode, chownErr error) (data, dir string, calls *[]call, logged *strings.Builder) {
		data = tmp(t)
		if err := os.Chmod(data, mode); err != nil {
			t.Fatal(err)
		}
		parent := filepath.Join(data, "AppData")
		if err := os.Mkdir(parent, 0o755); err != nil {
			t.Fatal(err)
		}
		repaired := false
		calls = &[]call{}
		owner, root, ch := trusted, dataRoot, chown
		trusted = func(uid int) bool { return uid == 0 || (repaired && uid == self) }
		dataRoot = data
		chown = func(p string, u, g int) error {
			*calls = append(*calls, call{p, u, g})
			if chownErr != nil {
				return chownErr
			}
			repaired = true
			return nil
		}
		logged = &strings.Builder{}
		log.SetOutput(logged)
		t.Cleanup(func() { trusted, dataRoot, chown = owner, root, ch; log.SetOutput(os.Stderr) })
		return data, filepath.Join(parent, "cron"), calls, logged
	}
	t.Run("repaired and logged", func(t *testing.T) {
		data, dir, calls, logged := setup(t, 0o755, nil)
		if err := Secure(dir); err != nil {
			t.Fatal(err)
		}
		if len(*calls) != 1 || (*calls)[0] != (call{data, 0, 0}) {
			t.Fatalf("chown calls %v, want one on %s", *calls, data)
		}
		want := data + " belonged to uid " + strconv.Itoa(self)
		if !strings.Contains(logged.String(), want) || !strings.Contains(logged.String(), "owner set to root (back: chown "+strconv.Itoa(self)+":") {
			t.Fatalf("log %q, want %q and the way back", logged.String(), want)
		}
		if fi, _ := os.Stat(data); fi.Mode().Perm() != 0o755 {
			t.Fatalf("mode of %s changed to %v", data, fi.Mode())
		}
	})
	t.Run("another ancestor is not repaired", func(t *testing.T) {
		_, dir, calls, _ := setup(t, 0o755, nil)
		dataRoot = "/DATA-not-on-this-path"
		if err := Secure(dir); err == nil || !strings.Contains(err.Error(), "lets others change the path") {
			t.Fatalf("err %v", err)
		}
		if len(*calls) != 0 {
			t.Fatalf("chown calls %v", *calls)
		}
	})
	t.Run("symlinked /DATA is refused, not repaired", func(t *testing.T) {
		data, _, calls, _ := setup(t, 0o755, nil)
		link := filepath.Join(tmp(t), "DATA")
		if err := os.Symlink(data, link); err != nil {
			t.Fatal(err)
		}
		dataRoot = link
		err := Secure(filepath.Join(link, "AppData", "cron"))
		if len(*calls) != 0 {
			t.Fatalf("chown calls %v on a symlink", *calls)
		}
		if err == nil || !strings.Contains(err.Error(), link+" (mode") {
			t.Fatalf("err %v, want %s refused", err, link)
		}
	})
	t.Run("chown fails", func(t *testing.T) {
		data, dir, _, _ := setup(t, 0o755, errors.New("operation not permitted"))
		if err := Secure(dir); err == nil || !strings.Contains(err.Error(), data+" belongs to uid") || !strings.Contains(err.Error(), "owner root not set") {
			t.Fatalf("err %v", err)
		}
	})
	t.Run("unsafe mode stays refused after the repair", func(t *testing.T) {
		data, dir, calls, _ := setup(t, 0o777, nil)
		if err := Secure(dir); err == nil || !strings.Contains(err.Error(), data+" (mode") {
			t.Fatalf("err %v, want %s refused for its mode", err, data)
		}
		if len(*calls) != 1 {
			t.Fatalf("chown calls %v", *calls)
		}
	})
}
