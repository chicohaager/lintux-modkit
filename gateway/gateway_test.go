package gateway

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestRegisterPostsTheRoute(t *testing.T) {
	var got map[string]string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/v1/gateway/routes" || r.Header.Get("Content-Type") != "application/json" {
			t.Errorf("unexpected request %s %s %q", r.Method, r.URL.Path, r.Header.Get("Content-Type"))
		}
		_ = json.NewDecoder(r.Body).Decode(&got)
		w.WriteHeader(http.StatusCreated)
	}))
	defer srv.Close()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "management.url"), []byte(srv.URL+"/\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := Register(context.Background(), dir, "/v2/demo", "http://127.0.0.1:1234", time.Second); err != nil {
		t.Fatal(err)
	}
	if got["path"] != "/v2/demo" || got["target"] != "http://127.0.0.1:1234" {
		t.Fatalf("route body %v", got)
	}
}

func TestRegisterReportsARefusal(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusBadRequest) }))
	defer srv.Close()
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "management.url"), []byte(srv.URL), 0o644)
	if err := Register(context.Background(), dir, "/v2/demo", "http://127.0.0.1:1", time.Second); err == nil {
		t.Fatal("a 400 from the gateway must be an error")
	}
}

func TestManagementURLWaitsForTheFile(t *testing.T) {
	dir := t.TempDir()
	go func() {
		time.Sleep(1200 * time.Millisecond)
		_ = os.WriteFile(filepath.Join(dir, "management.url"), []byte("http://127.0.0.1:9\n"), 0o644)
	}()
	start := time.Now()
	base, err := ManagementURL(context.Background(), dir, 5*time.Second)
	if err != nil || base != "http://127.0.0.1:9" {
		t.Fatalf("got %q, %v", base, err)
	}
	if time.Since(start) < time.Second {
		t.Fatal("returned before the file existed")
	}
	if _, err := ManagementURL(context.Background(), t.TempDir(), 1500*time.Millisecond); err == nil {
		t.Fatal("a missing file must be an error after the wait")
	}
}
