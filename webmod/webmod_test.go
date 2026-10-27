package webmod

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func testHandler(t *testing.T) http.Handler {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte("<h1>ui</h1>"), 0o644); err != nil {
		t.Fatal(err)
	}
	o := Options{Name: "demo", Service: "demo-web", Route: "/demo", Version: "1.2.3",
		API: func(verify func(http.Handler) http.Handler) http.Handler {
			mux := http.NewServeMux()
			mux.Handle("/demo/things", verify(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				_, _ = w.Write([]byte("things"))
			})))
			return mux
		}}
	// A verifier that admits only "Bearer good" stands in for auth.
	verify := func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Header.Get("Authorization") != "Bearer good" {
				http.Error(w, "no", http.StatusUnauthorized)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
	return Handler(o, verify, dir)
}

func do(h http.Handler, method, path string, hdr map[string]string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, "http://zima.local"+path, nil)
	for k, v := range hdr {
		r.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func TestHealthIsOpenAndReportsTheVersion(t *testing.T) {
	w := do(testHandler(t), "GET", "/demo/health", nil)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"version":"1.2.3"`) {
		t.Fatalf("health: %d %s", w.Code, w.Body)
	}
}

func TestAPINeedsTheToken(t *testing.T) {
	h := testHandler(t)
	if w := do(h, "GET", "/demo/things", nil); w.Code != http.StatusUnauthorized {
		t.Fatalf("without token: %d", w.Code)
	}
	if w := do(h, "GET", "/demo/things", map[string]string{"Authorization": "Bearer good"}); w.Code != 200 || w.Body.String() != "things" {
		t.Fatalf("with token: %d %s", w.Code, w.Body)
	}
}

func TestCrossOriginPostIsRejected(t *testing.T) {
	h := testHandler(t)
	w := do(h, "POST", "/demo/things", map[string]string{"Authorization": "Bearer good", "Origin": "http://evil.example"})
	if w.Code != http.StatusForbidden {
		t.Fatalf("cross-origin POST: %d", w.Code)
	}
	w = do(h, "POST", "/demo/things", map[string]string{"Authorization": "Bearer good", "Origin": "http://zima.local"})
	if w.Code != 200 {
		t.Fatalf("same-origin POST: %d %s", w.Code, w.Body)
	}
}

func TestUIIsServedUnderModules(t *testing.T) {
	w := do(testHandler(t), "GET", "/modules/demo/", nil) // FileServer answers .../index.html with a 301 to .../
	if w.Code != 200 || !strings.Contains(w.Body.String(), "<h1>ui</h1>") {
		t.Fatalf("ui: %d %s", w.Code, w.Body)
	}
}

func TestEnvPrefix(t *testing.T) {
	if got := envPrefix("wireguard-web"); got != "WIREGUARD_WEB" {
		t.Fatalf("envPrefix = %q", got)
	}
}

// A module's data directory under /DATA/AppData is checked before anything else
// (appdata.Secure): a symlink planted there must stop the start.
func TestDataDirsAreSecuredBeforeTheStart(t *testing.T) {
	base := t.TempDir()
	if err := os.Chmod(base, 0o755); err != nil {
		t.Fatal(err)
	}
	ok := filepath.Join(base, "good")
	if err := secureDataDirs([]string{ok}); err != nil {
		t.Fatalf("a fresh directory: %v", err)
	}
	link := filepath.Join(base, "planted")
	if err := os.Symlink(t.TempDir(), link); err != nil {
		t.Fatal(err)
	}
	if err := secureDataDirs([]string{ok, link}); err == nil || !strings.Contains(err.Error(), link) {
		t.Fatalf("err %v, want a refusal naming %s", err, link)
	}
}

func TestHealthTellsAReplacedBinary(t *testing.T) {
	dir := t.TempDir()
	running, file := filepath.Join(dir, "running"), filepath.Join(dir, "file")
	_ = os.WriteFile(running, []byte("program v1"), 0o755)
	_ = os.WriteFile(file, []byte("program v1"), 0o755)
	old := selfExe
	selfExe = running
	t.Cleanup(func() { selfExe = old })
	o := Options{Name: "demo", Service: "demo-web", Route: "/demo", Version: "1.2.3", Binary: file,
		API: func(func(http.Handler) http.Handler) http.Handler { return http.NotFoundHandler() }}
	h := Handler(o, func(n http.Handler) http.Handler { return n }, dir)
	state := func() string {
		w := do(h, "GET", "/demo/health", nil)
		var v map[string]string
		if err := json.Unmarshal(w.Body.Bytes(), &v); err != nil || v["status"] != "ok" {
			t.Fatalf("health: %d %s", w.Code, w.Body)
		}
		return v["binary"]
	}
	if s := state(); s != "current" {
		t.Fatalf("same program: %q", s)
	}
	// the module was updated: a new file, the process still runs v1
	_ = os.WriteFile(file, []byte("program v2, longer"), 0o755)
	if s := state(); s != "replaced" {
		t.Fatalf("new file: %q", s)
	}
	// back to v1 with the same size and mtime as v2, but a new file (new inode), as a sysext swap does
	fi, _ := os.Stat(file)
	_ = os.Remove(file)
	_ = os.WriteFile(file, []byte("program v1, longer"), 0o755)
	_ = os.Chtimes(file, fi.ModTime(), fi.ModTime())
	_ = os.WriteFile(running, []byte("program v1, longer"), 0o755)
	b2 := Handler(o, func(n http.Handler) http.Handler { return n }, dir) // a new process: reads its program again
	if w := do(b2, "GET", "/demo/health", nil); !strings.Contains(w.Body.String(), `"binary":"current"`) {
		t.Fatalf("new process, same program: %s", w.Body)
	}
	_ = os.Remove(file)
	_ = os.WriteFile(file, []byte("program v3, longer"), 0o755) // same size, new inode
	_ = os.Chtimes(file, fi.ModTime(), fi.ModTime())
	if w := do(b2, "GET", "/demo/health", nil); !strings.Contains(w.Body.String(), `"binary":"replaced"`) {
		t.Fatalf("same size and mtime, new content: %s", w.Body)
	}
	_ = os.Remove(file)
	if s := state(); s != "unknown" {
		t.Fatalf("no file: %q", s)
	}
	if w := do(testHandler(t), "GET", "/demo/health", nil); !strings.Contains(w.Body.String(), `"binary":"unknown"`) {
		t.Fatalf("no Binary set: %s", w.Body)
	}
}
