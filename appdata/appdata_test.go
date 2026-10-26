package appdata

import (
	"os"
	"path/filepath"
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
