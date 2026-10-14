package relay

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
)

const phoneToken = "phone-token-1"

type harness struct {
	t     *testing.T
	dir   string
	relay *Server
	ts    *httptest.Server
	ws    string
}

func newHarness(t *testing.T, cfg Config) *harness {
	t.Helper()
	dir := t.TempDir()
	return startHarness(t, dir, cfg)
}

func startHarness(t *testing.T, dir string, cfg Config) *harness {
	t.Helper()
	store, err := OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.SessionTimeout == 0 {
		cfg.SessionTimeout = 2 * time.Second
	}
	cfg.Logger = slog.New(slog.NewTextHandler(io.Discard, nil))
	h := &harness{t: t, dir: dir, relay: NewServer(store, cfg)}
	h.ts = httptest.NewServer(h.relay)
	h.ws = "ws" + strings.TrimPrefix(h.ts.URL, "http")
	t.Cleanup(h.stop)
	return h
}

func (h *harness) stop() {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = h.relay.Shutdown(ctx)
	h.ts.Close()
}

func dial(t *testing.T, url, token string) (*websocket.Conn, int, error) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, resp, err := websocket.Dial(ctx, url, &websocket.DialOptions{
		HTTPHeader: http.Header{"Authorization": {"Bearer " + token}},
	})
	status := 0
	if resp != nil {
		status = resp.StatusCode
	}
	if c != nil {
		t.Cleanup(func() { c.CloseNow() })
	}
	return c, status, err
}

func ctx5(t *testing.T) context.Context {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	t.Cleanup(cancel)
	return ctx
}

func eventually(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatal("condition not met in time")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// fakeMac is a simulated Mac: a control connection that answers every
// "incoming" notice by opening the session half and handing it to sessions.
type fakeMac struct {
	id, secret string
	control    *websocket.Conn
	sessions   chan *websocket.Conn
	answer     atomic.Bool
	closed     chan error // the control connection's final read error
}

func (h *harness) connectMac(id, secret string, tokens ...string) *fakeMac {
	h.t.Helper()
	c, status, err := dial(h.t, h.ws+"/v1/mac/"+id+"/control", secret)
	if err != nil {
		h.t.Fatalf("control dial: %v (status %d)", err, status)
	}
	m := &fakeMac{id: id, secret: secret, control: c, sessions: make(chan *websocket.Conn, 64), closed: make(chan error, 1)}
	m.answer.Store(true)
	m.setTokens(h.t, tokens...)
	eventually(h.t, func() bool {
		return len(tokens) == 0 || h.relay.store.TokenAllowed(id, tokens[len(tokens)-1])
	})
	go func() {
		for {
			typ, data, err := c.Read(context.Background())
			if err != nil {
				m.closed <- err
				return
			}
			var msg struct{ Type, Session string }
			if typ != websocket.MessageText || json.Unmarshal(data, &msg) != nil || msg.Type != "incoming" || !m.answer.Load() {
				continue
			}
			// Not dial(): t.Cleanup must not be called from this goroutine.
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			sc, _, err := websocket.Dial(ctx, h.ws+"/v1/mac/"+id+"/session/"+msg.Session, &websocket.DialOptions{
				HTTPHeader: http.Header{"Authorization": {"Bearer " + secret}},
			})
			cancel()
			if err == nil {
				m.sessions <- sc
			}
		}
	}()
	return m
}

func (m *fakeMac) setTokens(t *testing.T, tokens ...string) {
	t.Helper()
	if tokens == nil {
		return // like a Mac that has not sent its list yet
	}
	hashes := []string{}
	for _, tok := range tokens {
		hashes = append(hashes, hashCredential(tok))
	}
	data, _ := json.Marshal(map[string]any{"type": "tokens", "hashes": hashes})
	if err := m.control.Write(ctx5(t), websocket.MessageText, data); err != nil {
		t.Fatal(err)
	}
}

func (m *fakeMac) nextSession(t *testing.T) *websocket.Conn {
	t.Helper()
	select {
	case c := <-m.sessions:
		t.Cleanup(func() { c.CloseNow() })
		return c
	case <-time.After(5 * time.Second):
		t.Fatal("mac never got a session")
		return nil
	}
}

func (h *harness) connectPhone(macID, token string) (*websocket.Conn, int, error) {
	return dial(h.t, h.ws+"/v1/connect/"+macID, token)
}

func mustSend(t *testing.T, c *websocket.Conn, payload []byte) {
	t.Helper()
	if err := c.Write(ctx5(t), websocket.MessageBinary, payload); err != nil {
		t.Fatal(err)
	}
}

func mustRecv(t *testing.T, c *websocket.Conn, want []byte) {
	t.Helper()
	typ, got, err := c.Read(ctx5(t))
	if err != nil {
		t.Fatal(err)
	}
	if typ != websocket.MessageBinary || !bytes.Equal(got, want) {
		t.Fatalf("got %v %q, want binary %q", typ, got, want)
	}
}

func TestHealthz(t *testing.T) {
	h := newHarness(t, Config{})
	resp, err := http.Get(h.ts.URL + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 || string(body) != "ok" {
		t.Fatalf("healthz = %d %q", resp.StatusCode, body)
	}
}

func TestControlTOFUAndWrongSecret(t *testing.T) {
	h := newHarness(t, Config{})
	id := newID()
	h.connectMac(id, "secret-a")

	if _, status, err := dial(t, h.ws+"/v1/mac/"+id+"/control", "secret-b"); err == nil || status != http.StatusForbidden {
		t.Fatalf("wrong secret: status %d err %v, want 403", status, err)
	}
	if _, status, _ := dial(t, h.ws+"/v1/mac/not-a-mac-id/control", "x"); status != http.StatusBadRequest {
		t.Fatalf("bad mac id: status %d, want 400", status)
	}
	// The right secret still works and replaces the first control connection.
	h.connectMac(id, "secret-a")
}

func TestControlReplacesOld(t *testing.T) {
	h := newHarness(t, Config{})
	id := newID()
	first := h.connectMac(id, "s")
	h.connectMac(id, "s")
	var err error
	select {
	case err = <-first.closed:
	case <-time.After(5 * time.Second):
		t.Fatal("old control not closed")
	}
	if got := websocket.CloseStatus(err); got != StatusReplaced {
		t.Fatalf("old control closed with %v, want %v", got, StatusReplaced)
	}
}

func TestPhoneUnknownTokenForbidden(t *testing.T) {
	h := newHarness(t, Config{})
	id := newID()
	h.connectMac(id, "s", phoneToken)
	if _, status, _ := h.connectPhone(id, "someone-else"); status != http.StatusForbidden {
		t.Fatalf("status %d, want 403", status)
	}
	if _, status, _ := h.connectPhone(newID(), phoneToken); status != http.StatusForbidden {
		t.Fatalf("unknown mac: status %d, want 403", status)
	}
}

func TestPhoneMacOffline(t *testing.T) {
	h := newHarness(t, Config{})
	id := newID()
	m := h.connectMac(id, "s", phoneToken)
	m.control.Close(websocket.StatusNormalClosure, "")
	eventually(t, func() bool {
		h.relay.mu.Lock()
		defer h.relay.mu.Unlock()
		return h.relay.macs[id].control == nil
	})
	if _, status, _ := h.connectPhone(id, phoneToken); status != http.StatusNotFound {
		t.Fatalf("status %d, want 404", status)
	}
}

func TestSessionEchoAndCloseFromPhone(t *testing.T) {
	h := newHarness(t, Config{})
	id := newID()
	m := h.connectMac(id, "s", phoneToken)

	phone, status, err := h.connectPhone(id, phoneToken)
	if err != nil {
		t.Fatalf("connect: %v (status %d)", err, status)
	}
	mac := m.nextSession(t)

	mustSend(t, phone, []byte("client hello"))
	mustRecv(t, mac, []byte("client hello"))
	mustSend(t, mac, []byte{0, 1, 2, 255})
	mustRecv(t, phone, []byte{0, 1, 2, 255})

	phone.Close(websocket.StatusNormalClosure, "bye")
	if _, _, err := mac.Read(ctx5(t)); err == nil {
		t.Fatal("mac half still open after phone closed")
	}
}

func TestSessionCloseFromMac(t *testing.T) {
	h := newHarness(t, Config{})
	id := newID()
	m := h.connectMac(id, "s", phoneToken)
	phone, _, err := h.connectPhone(id, phoneToken)
	if err != nil {
		t.Fatal(err)
	}
	mac := m.nextSession(t)
	mac.Close(websocket.StatusNormalClosure, "bye")
	if _, _, err := phone.Read(ctx5(t)); err == nil {
		t.Fatal("phone still open after mac closed")
	}
}

func TestSessionMacNeverAnswers(t *testing.T) {
	h := newHarness(t, Config{SessionTimeout: 200 * time.Millisecond})
	id := newID()
	m := h.connectMac(id, "s", phoneToken)
	m.answer.Store(false)
	phone, _, err := h.connectPhone(id, phoneToken)
	if err != nil {
		t.Fatal(err)
	}
	_, _, err = phone.Read(ctx5(t))
	if got := websocket.CloseStatus(err); got != StatusMacTimeout {
		t.Fatalf("close status %v, want %v", got, StatusMacTimeout)
	}
}

func TestMacSessionUnknownOrWrongSecret(t *testing.T) {
	h := newHarness(t, Config{})
	id := newID()
	h.connectMac(id, "s")
	if _, status, _ := dial(t, h.ws+"/v1/mac/"+id+"/session/"+newID(), "s"); status != http.StatusNotFound {
		t.Fatalf("unknown session: status %d, want 404", status)
	}
	if _, status, _ := dial(t, h.ws+"/v1/mac/"+id+"/session/"+newID(), "wrong"); status != http.StatusForbidden {
		t.Fatalf("wrong secret: status %d, want 403", status)
	}
}

func TestSessionLimit(t *testing.T) {
	h := newHarness(t, Config{MaxSessionsPerMac: 2})
	id := newID()
	m := h.connectMac(id, "s", phoneToken)
	for range 2 {
		if _, _, err := h.connectPhone(id, phoneToken); err != nil {
			t.Fatal(err)
		}
		m.nextSession(t)
	}
	if _, status, _ := h.connectPhone(id, phoneToken); status != http.StatusTooManyRequests {
		t.Fatalf("status %d, want 429", status)
	}
}

func TestConnectRateLimit(t *testing.T) {
	h := newHarness(t, Config{ConnectsPerMinute: 3})
	id := newID()
	m := h.connectMac(id, "s", phoneToken)
	for range 3 {
		phone, _, err := h.connectPhone(id, phoneToken)
		if err != nil {
			t.Fatal(err)
		}
		m.nextSession(t)
		phone.Close(websocket.StatusNormalClosure, "")
	}
	if _, status, _ := h.connectPhone(id, phoneToken); status != http.StatusTooManyRequests {
		t.Fatalf("status %d, want 429", status)
	}
}

func TestTokenUpdateRevokesNewConnects(t *testing.T) {
	h := newHarness(t, Config{})
	id := newID()
	m := h.connectMac(id, "s", phoneToken, "other")
	if _, _, err := h.connectPhone(id, phoneToken); err != nil {
		t.Fatal(err)
	}
	m.nextSession(t)

	m.setTokens(t, "other")
	eventually(t, func() bool { return !h.relay.store.TokenAllowed(id, phoneToken) })
	if _, status, _ := h.connectPhone(id, phoneToken); status != http.StatusForbidden {
		t.Fatalf("revoked token: status %d, want 403", status)
	}
}

func TestInvalidTokenHashesClosesControl(t *testing.T) {
	h := newHarness(t, Config{})
	m := h.connectMac(newID(), "s")
	data := []byte(`{"type":"tokens","hashes":["not-a-hash"]}`)
	if err := m.control.Write(ctx5(t), websocket.MessageText, data); err != nil {
		t.Fatal(err)
	}
	var err error
	select {
	case err = <-m.closed:
	case <-time.After(5 * time.Second):
		t.Fatal("control not closed")
	}
	if got := websocket.CloseStatus(err); got != websocket.StatusPolicyViolation {
		t.Fatalf("close status %v, want policy violation", got)
	}
}

func TestPersistenceReload(t *testing.T) {
	dir := t.TempDir()
	id := newID()
	h := startHarness(t, dir, Config{})
	h.connectMac(id, "s", phoneToken)
	h.stop()

	store, err := OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	if !store.TokenAllowed(id, phoneToken) {
		t.Fatal("token hash not persisted")
	}
	if ok, _ := store.AuthenticateMac(id, "s", false); !ok {
		t.Fatal("registration not persisted")
	}
	if ok, _ := store.AuthenticateMac(id, "other", true); ok {
		t.Fatal("reloaded store accepted another secret")
	}

	// A fresh relay on the same data dir lets the phone in once the Mac is back,
	// even before the Mac resends its token list.
	h2 := startHarness(t, dir, Config{})
	m := h2.connectMac(id, "s")
	if _, _, err := h2.connectPhone(id, phoneToken); err != nil {
		t.Fatal(err)
	}
	m.nextSession(t)
}

func TestShutdownClosesConnections(t *testing.T) {
	h := newHarness(t, Config{})
	id := newID()
	m := h.connectMac(id, "s", phoneToken)
	phone, _, err := h.connectPhone(id, phoneToken)
	if err != nil {
		t.Fatal(err)
	}
	mac := m.nextSession(t)
	// Both clients keep reading, as real ones do, so close handshakes complete.
	errc := make(chan error, 2)
	for _, c := range []*websocket.Conn{phone, mac} {
		go func() { _, _, err := c.Read(context.Background()); errc <- err }()
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := h.relay.Shutdown(ctx); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		if err := <-errc; err == nil {
			t.Fatal("client still open after shutdown")
		}
	}
}

func TestMissedPongDropsConnection(t *testing.T) {
	h := newHarness(t, Config{PingInterval: 50 * time.Millisecond})
	// A control client that never reads cannot answer pings.
	_, status, err := dial(t, h.ws+"/v1/mac/"+newID()+"/control", "s")
	if err != nil {
		t.Fatalf("dial: %v (%d)", err, status)
	}
	eventually(t, func() bool {
		h.relay.mu.Lock()
		defer h.relay.mu.Unlock()
		for _, st := range h.relay.macs {
			if st.control != nil {
				return false
			}
		}
		return len(h.relay.macs) == 1
	})
}

func TestClientIP(t *testing.T) {
	cases := []struct {
		remote, cf, xff, want string
	}{
		{"203.0.113.5:1234", "198.51.100.1", "", "203.0.113.5"},
		{"127.0.0.1:1234", "198.51.100.1", "10.0.0.1", "198.51.100.1"},
		{"127.0.0.1:1234", "", "198.51.100.2, 10.0.0.1", "198.51.100.2"},
		{"[::1]:1234", "", "", "::1"},
	}
	for _, c := range cases {
		r := httptest.NewRequest("GET", "/", nil)
		r.RemoteAddr = c.remote
		if c.cf != "" {
			r.Header.Set("CF-Connecting-IP", c.cf)
		}
		if c.xff != "" {
			r.Header.Set("X-Forwarded-For", c.xff)
		}
		if got := clientIP(r); got != c.want {
			t.Errorf("clientIP(%+v) = %q, want %q", c, got, c.want)
		}
	}
}

func TestRateLimiterWindow(t *testing.T) {
	now := time.Unix(0, 0)
	l := newRateLimiter(2, time.Minute)
	l.now = func() time.Time { return now }
	if !l.allow("k") || !l.allow("k") || l.allow("k") {
		t.Fatal("limit not enforced")
	}
	now = now.Add(61 * time.Second)
	if !l.allow("k") {
		t.Fatal("window did not slide")
	}
}

func TestRegistrationRateLimitSparesKnownMacs(t *testing.T) {
	h := newHarness(t, Config{RegistrationsPerHour: 2})
	first, second := newID(), newID()
	h.connectMac(first, "s1")
	h.connectMac(second, "s2")
	if _, status, err := dial(t, h.ws+"/v1/mac/"+newID()+"/control", "s3"); err == nil || status != http.StatusTooManyRequests {
		t.Fatalf("third registration: status %d err %v, want 429", status, err)
	}
	// Reconnecting a registered Mac is not a registration.
	h.connectMac(first, "s1")
}
