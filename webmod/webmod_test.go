package webmod

import (
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
