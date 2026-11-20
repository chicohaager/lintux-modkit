package auth

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

// The claims of a sub-account as ZimaOS 1.8.0 issues them (measured 2026-11-20 on a
// ZimaBoard 2: an account made with POST /v2/users/samba/user logged in through
// /v1/users/login carries role "user", id 10000 and its username; the main account
// carries role "admin", id 1).
func memberClaims(exp string) string {
	return `{"username":"kid","role":"user","id":10000,"iss":"zimaos","exp":` + exp + `,"nbf":0,"iat":0}`
}

func TestSessionReadsTheAccount(t *testing.T) {
	key, v := newKeyAndServer(t)
	exp := strconv.FormatInt(time.Now().Add(time.Hour).Unix(), 10)
	s, err := v.Session(signClaims(t, key, memberClaims(exp)))
	if err != nil {
		t.Fatalf("member session rejected: %v", err)
	}
	if s.Username != "kid" || s.ID != 10000 || s.Role != "user" || s.Admin() {
		t.Fatalf("session = %+v", s)
	}
	a, err := v.Session(signClaims(t, key, `{"username":"owner","role":"admin","id":1,"iss":"zimaos","exp":`+exp+`}`))
	if err != nil || !a.Admin() || a.Username != "owner" || a.ID != 1 {
		t.Fatalf("admin session = %+v, %v", a, err)
	}
}

func TestSessionRefusesUnknownRoles(t *testing.T) {
	key, v := newKeyAndServer(t)
	exp := strconv.FormatInt(time.Now().Add(time.Hour).Unix(), 10)
	for name, claims := range map[string]string{
		"guest":        `{"username":"x","iss":"zimaos","exp":` + exp + `,"role":"guest"}`,
		"no role":      `{"username":"x","iss":"zimaos","exp":` + exp + `}`,
		"empty role":   `{"username":"x","iss":"zimaos","exp":` + exp + `,"role":""}`,
		"upper case":   `{"username":"x","iss":"zimaos","exp":` + exp + `,"role":"User"}`,
		"role as list": `{"username":"x","iss":"zimaos","exp":` + exp + `,"role":["user"]}`,
		"no username":  `{"iss":"zimaos","exp":` + exp + `,"role":"user"}`,
	} {
		if _, err := v.Session(signClaims(t, key, claims)); !errors.Is(err, ErrNotMember) {
			t.Errorf("%s: err = %v, want ErrNotMember", name, err)
		}
	}
	// the refresh token and an expired session stay refused as with Verify
	if _, err := v.Session(signClaims(t, key, `{"username":"x","iss":"refresh","exp":`+exp+`,"role":"user"}`)); err == nil {
		t.Error("refresh token accepted as a session")
	}
	old := strconv.FormatInt(time.Now().Add(-time.Minute).Unix(), 10)
	if _, err := v.Session(signClaims(t, key, memberClaims(old))); err == nil || !strings.Contains(err.Error(), "expired") {
		t.Errorf("expired member token: %v", err)
	}
}

func TestVerifyStillWantsTheAdmin(t *testing.T) {
	key, v := newKeyAndServer(t)
	exp := strconv.FormatInt(time.Now().Add(time.Hour).Unix(), 10)
	if err := v.Verify(signClaims(t, key, memberClaims(exp))); !errors.Is(err, ErrNotAdmin) {
		t.Fatalf("member passed Verify: %v", err)
	}
}

func TestMemberMiddlewareLetsEveryAccountInAndRequireAdminSplits(t *testing.T) {
	key, v := newKeyAndServer(t)
	exp := strconv.FormatInt(time.Now().Add(time.Hour).Unix(), 10)
	member := "Bearer " + signClaims(t, key, memberClaims(exp))
	admin := "Bearer " + signClaims(t, key, `{"username":"owner","role":"admin","id":1,"iss":"zimaos","exp":`+exp+`}`)

	who := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s, ok := SessionFrom(r.Context())
		if !ok {
			http.Error(w, "no session in context", 500)
			return
		}
		_, _ = w.Write([]byte(s.Username))
	})
	mux := http.NewServeMux()
	mux.Handle("/listen", who)
	mux.Handle("/settings", RequireAdmin(who))
	h := v.MemberMiddleware(mux)

	for _, c := range []struct {
		path, token string
		code        int
		body        string
	}{
		{"/listen", member, 200, "kid"},
		{"/listen", admin, 200, "owner"},
		{"/settings", admin, 200, "owner"},
		{"/settings", member, 403, "auth_forbidden"},
		{"/listen", "", 401, "auth_required"},
	} {
		req := httptest.NewRequest("GET", c.path, nil)
		if c.token != "" {
			req.Header.Set("Authorization", c.token)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != c.code || !strings.Contains(rec.Body.String(), c.body) {
			t.Errorf("%s with %.12q: %d %q, want %d containing %q", c.path, c.token, rec.Code, rec.Body.String(), c.code, c.body)
		}
	}
}

func TestAdminMiddlewarePutsTheSessionInTheContext(t *testing.T) {
	key, v := newKeyAndServer(t)
	exp := strconv.FormatInt(time.Now().Add(time.Hour).Unix(), 10)
	req := httptest.NewRequest("GET", "/", nil)
	req.Header.Set("Authorization", "Bearer "+signClaims(t, key, `{"username":"owner","role":"admin","id":1,"iss":"zimaos","exp":`+exp+`}`))
	rec := httptest.NewRecorder()
	v.Middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s, ok := SessionFrom(r.Context()); !ok || s.Username != "owner" || !s.Admin() {
			t.Errorf("session = %+v, %v", s, ok)
		}
	})).ServeHTTP(rec, req)
	if rec.Code != 200 {
		t.Fatalf("code %d", rec.Code)
	}
}

func TestRequireAdminWithoutSessionIsClosed(t *testing.T) {
	rec := httptest.NewRecorder()
	RequireAdmin(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		t.Error("handler ran without a session")
	})).ServeHTTP(rec, httptest.NewRequest("GET", "/", nil))
	if rec.Code != http.StatusForbidden {
		t.Fatalf("code %d, want 403", rec.Code)
	}
}

func TestDisabledVerifierActsAsAdmin(t *testing.T) {
	rec := httptest.NewRecorder()
	Disabled().MemberMiddleware(RequireAdmin(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s, _ := SessionFrom(r.Context())
		_, _ = w.Write([]byte(s.Username))
	}))).ServeHTTP(rec, httptest.NewRequest("GET", "/", nil))
	if rec.Code != 200 || rec.Body.String() != "dev" {
		t.Fatalf("%d %q", rec.Code, rec.Body.String())
	}
}
