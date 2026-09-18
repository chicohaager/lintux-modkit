package httpx

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func ok(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) }

func TestWriteErrMapsCodes(t *testing.T) {
	rec := httptest.NewRecorder()
	WriteErr(rec, BadRequest("name_required", "name is %s", "required"))
	var body map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if rec.Code != 400 || body["code"] != "name_required" || body["error"] != "name is required" {
		t.Fatalf("got %d %v", rec.Code, body)
	}
	rec = httptest.NewRecorder()
	WriteErr(rec, errors.New("disk on fire"))
	if rec.Code != 500 || !strings.Contains(rec.Body.String(), `"internal"`) {
		t.Fatalf("plain error: %d %s", rec.Code, rec.Body.String())
	}
}

func TestCSRF(t *testing.T) {
	h := CSRF(http.HandlerFunc(ok))
	cases := []struct {
		method, origin string
		want           int
	}{
		{http.MethodGet, "http://evil.example", 200},
		{http.MethodPost, "", 200},
		{http.MethodPost, "http://example.com", 200},
		{http.MethodPost, "https://EXAMPLE.com", 200},
		{http.MethodPost, "http://evil.example", 403},
		{http.MethodDelete, "http://evil.example", 403},
	}
	for _, c := range cases {
		req := httptest.NewRequest(c.method, "http://example.com/x", nil)
		if c.origin != "" {
			req.Header.Set("Origin", c.origin)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != c.want {
			t.Errorf("%s origin=%q: got %d want %d", c.method, c.origin, rec.Code, c.want)
		}
	}
}

func TestLoggingCapsBody(t *testing.T) {
	h := Logging("t", 10)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var v map[string]string
		if !Decode(w, r, &v) {
			return
		}
		w.WriteHeader(200)
	}))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/x", strings.NewReader(`{"k":"`+strings.Repeat("a", 50)+`"}`)))
	if rec.Code != 400 {
		t.Fatalf("oversized body accepted: %d", rec.Code)
	}
}

func TestStaticServesUnderPrefixAndBlocksTraversal(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte("<h1>ui</h1>"), 0644); err != nil {
		t.Fatal(err)
	}
	h := Static("/modules/x/", dir, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(418) }))
	get := func(p string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, p, nil))
		return rec
	}
	if rec := get("/modules/x/"); rec.Code != 200 || !strings.Contains(rec.Body.String(), "ui") {
		t.Errorf("index: %d %s", rec.Code, rec.Body.String())
	}
	if rec := get("/"); rec.Code != 302 || rec.Header().Get("Location") != "/modules/x/" {
		t.Errorf("root redirect: %d %s", rec.Code, rec.Header().Get("Location"))
	}
	if rec := get("/modules/x/../../etc/passwd"); rec.Code == 200 {
		t.Error("traversal served")
	}
	if rec := get("/api/whatever"); rec.Code != 418 {
		t.Errorf("non-static path not passed through: %d", rec.Code)
	}
}
