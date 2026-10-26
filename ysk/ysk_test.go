package ysk

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type bus struct {
	events []string
	bodies []map[string]string
	status int
}

func newBus(t *testing.T) (*bus, string) {
	b := &bus{status: http.StatusOK}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		var m map[string]string
		_ = json.Unmarshal(raw, &m)
		b.events = append(b.events, strings.TrimPrefix(r.URL.Path, "/v2/message_bus/event/ysk/"))
		b.bodies = append(b.bodies, m)
		w.WriteHeader(b.status)
	}))
	t.Cleanup(srv.Close)
	f := filepath.Join(t.TempDir(), "message-bus.url")
	_ = os.WriteFile(f, []byte(srv.URL+"\n"), 0o644)
	return b, f
}

func TestShowSendsTheCardAsZimaOSExpectsIt(t *testing.T) {
	b, f := newBus(t)
	c := NewCard("demo:x", "Demo", "/modules/demo/appicon.svg", "2 things need you", "Open Demo", "modules/demo/index.html#tab")
	if err := (Notifier{BusURLFile: f}).Show(context.Background(), c); err != nil {
		t.Fatal(err)
	}
	if strings.Join(b.events, " ") != "ysk:card:upsert" {
		t.Fatalf("events %v", b.events)
	}
	// the form measured on ZimaOS 1.8.0 (KB §75): long-notice / icon-text-notice, one open_files button
	want := `{"id":"demo:x","cardType":"long-notice","renderType":"icon-text-notice","content":{"titleIcon":"/modules/demo/appicon.svg","titleText":"Demo","bodyIconWithText":{"icon":"/modules/demo/appicon.svg","description":"2 things need you"},"footerActions":[{"side":"right","style":"primary","text":"Open Demo","messageBus":{"key":"casaos-ui:open_files","payload":"{\"url\":\"modules/demo/index.html#tab\"}"}}]}}`
	if got := b.bodies[0]["card:body"]; got != want {
		t.Fatalf("card body\n got %s\nwant %s", got, want)
	}
}

func TestWithdrawNamesTheCard(t *testing.T) {
	b, f := newBus(t)
	if err := (Notifier{BusURLFile: f}).Withdraw(context.Background(), "demo:x"); err != nil {
		t.Fatal(err)
	}
	if strings.Join(b.events, " ") != "ysk:card:delete" || b.bodies[0]["card:id"] != "demo:x" {
		t.Fatalf("events %v bodies %v", b.events, b.bodies)
	}
}

func TestABusErrorIsAnError(t *testing.T) {
	b, f := newBus(t)
	b.status = http.StatusInternalServerError
	if err := (Notifier{BusURLFile: f}).Withdraw(context.Background(), "demo:x"); err == nil || !strings.Contains(err.Error(), "HTTP 500") {
		t.Fatalf("err %v", err)
	}
}

func TestTheBusIsOnlyReachedOnLoopback(t *testing.T) {
	f := filepath.Join(t.TempDir(), "message-bus.url")
	for _, u := range []string{"http://192.0.2.7:37065", "https://127.0.0.1:37065", "http://127.0.0.1.example.com:1"} {
		_ = os.WriteFile(f, []byte(u+"\n"), 0o644)
		if err := (Notifier{BusURLFile: f}).Withdraw(context.Background(), "demo:x"); err == nil || !strings.Contains(err.Error(), "loopback") {
			t.Errorf("%s: err %v, want a refusal", u, err)
		}
	}
}

func TestNoBusFileSendsNothing(t *testing.T) {
	if err := (Notifier{}).Show(context.Background(), NewCard("a", "b", "c", "d", "e", "f")); err != nil {
		t.Fatalf("an empty BusURLFile disables the card: %v", err)
	}
}
