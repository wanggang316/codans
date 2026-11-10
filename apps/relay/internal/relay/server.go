// Package relay implements the codans relay (protocol v1): a dumb pipe that
// pairs a phone's WebSocket with a Mac's WebSocket and forwards binary
// messages verbatim. The end-to-end TLS-PSK session runs inside the pipe, so
// the relay only sees ciphertext and routing IDs.
// See docs/design-docs/ios-companion.md, "Phase 3: Internet Access Through a Relay".
package relay

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// Close codes sent by the relay (4000–4999 are application-defined).
const (
	StatusReplaced       websocket.StatusCode = 4000 // a newer control connection took over
	StatusMacUnreachable websocket.StatusCode = 4502 // could not notify the Mac
	StatusMacTimeout     websocket.StatusCode = 4504 // the Mac never opened its session half
)

const maxTokenHashes = 1024

// Config tunes the relay. Zero values take the protocol defaults.
type Config struct {
	PingInterval      time.Duration // default 25 s
	SessionTimeout    time.Duration // how long a phone waits for the Mac; default 10 s
	MaxSessionsPerMac int           // default 32
	MaxMessageBytes   int64         // default 1 MiB
	ConnectsPerMinute int           // per Mac and per client IP; default 60
	// New Mac registrations per client IP per hour; default 10.
	RegistrationsPerHour int
	Logger               *slog.Logger
}

func (c *Config) setDefaults() {
	if c.PingInterval <= 0 {
		c.PingInterval = 25 * time.Second
	}
	if c.SessionTimeout <= 0 {
		c.SessionTimeout = 10 * time.Second
	}
	if c.MaxSessionsPerMac <= 0 {
		c.MaxSessionsPerMac = 32
	}
	if c.MaxMessageBytes <= 0 {
		c.MaxMessageBytes = 1 << 20
	}
	if c.ConnectsPerMinute <= 0 {
		c.ConnectsPerMinute = 60
	}
	if c.RegistrationsPerHour <= 0 {
		c.RegistrationsPerHour = 10
	}
	if c.Logger == nil {
		c.Logger = slog.Default()
	}
}

type macState struct {
	control  *websocket.Conn
	sessions int // reserved or active sessions
}

// macHalf is the Mac's session connection handed to the waiting phone handler;
// done is closed once the pipe ends so the Mac's handler can return.
type macHalf struct {
	conn *websocket.Conn
	done chan struct{}
}

type pendingSession struct {
	macID string
	ready chan *macHalf // buffered(1); receives nil if the Mac's upgrade failed
}

// Server is the relay's HTTP handler.
type Server struct {
	cfg     Config
	store   *Store
	log     *slog.Logger
	mux     *http.ServeMux
	macRate *rateLimiter
	ipRate  *rateLimiter
	// New registrations per client IP per hour.
	regRate *rateLimiter

	ctx    context.Context // canceled by Shutdown
	cancel context.CancelFunc
	conns  sync.WaitGroup

	mu      sync.Mutex
	macs    map[string]*macState
	pending map[string]*pendingSession
}

// NewServer returns a relay backed by store.
func NewServer(store *Store, cfg Config) *Server {
	cfg.setDefaults()
	ctx, cancel := context.WithCancel(context.Background())
	s := &Server{
		cfg:     cfg,
		store:   store,
		log:     cfg.Logger,
		mux:     http.NewServeMux(),
		macRate: newRateLimiter(cfg.ConnectsPerMinute, time.Minute),
		ipRate:  newRateLimiter(cfg.ConnectsPerMinute, time.Minute),
		regRate: newRateLimiter(cfg.RegistrationsPerHour, time.Hour),
		ctx:     ctx,
		cancel:  cancel,
		macs:    map[string]*macState{},
		pending: map[string]*pendingSession{},
	}
	s.mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok"))
	})
	s.mux.HandleFunc("GET /v1/mac/{macID}/control", s.handleControl)
	s.mux.HandleFunc("GET /v1/mac/{macID}/session/{sessionID}", s.handleMacSession)
	s.mux.HandleFunc("GET /v1/connect/{macID}", s.handleConnect)
	return s
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) { s.mux.ServeHTTP(w, r) }

// Shutdown closes every WebSocket with 1001 (going away) and waits for the
// handlers to finish or ctx to expire. Hijacked connections are invisible to
// http.Server.Shutdown, so this must be called alongside it.
func (s *Server) Shutdown(ctx context.Context) error {
	s.cancel()
	done := make(chan struct{})
	go func() { s.conns.Wait(); close(done) }()
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (s *Server) handleControl(w http.ResponseWriter, r *http.Request) {
	macID := r.PathValue("macID")
	log := s.log.With("mac", idPrefix(macID))
	if validID(macID) && !s.store.Registered(macID) && !s.regRate.allow(clientIP(r)) {
		log.Warn("registration rate limited", "ip", clientIP(r))
		http.Error(w, "too many registrations", http.StatusTooManyRequests)
		return
	}
	if !s.authenticateMac(w, r, macID, true) {
		return
	}
	conn, err := s.accept(w, r)
	if err != nil {
		return
	}
	defer s.track(conn)()

	s.mu.Lock()
	st := s.mac(macID)
	old := st.control
	st.control = conn
	s.mu.Unlock()
	if old != nil {
		go old.Close(StatusReplaced, "replaced by a newer control connection")
	}
	log.Info("mac control connected")

	defer func() {
		s.mu.Lock()
		if st.control == conn {
			st.control = nil
		}
		s.mu.Unlock()
		log.Info("mac control disconnected")
	}()

	for {
		typ, data, err := conn.Read(context.Background())
		if err != nil {
			return
		}
		if typ != websocket.MessageText {
			continue
		}
		var msg struct {
			Type   string   `json:"type"`
			Hashes []string `json:"hashes"`
		}
		if err := json.Unmarshal(data, &msg); err != nil {
			conn.Close(websocket.StatusPolicyViolation, "invalid control message")
			return
		}
		switch msg.Type {
		case "tokens":
			if !validTokenHashes(msg.Hashes) {
				conn.Close(websocket.StatusPolicyViolation, "invalid token hashes")
				return
			}
			if err := s.store.SetTokenHashes(macID, msg.Hashes); err != nil {
				log.Error("persist token hashes", "err", err)
			}
			log.Info("token hashes updated", "count", len(msg.Hashes))
		default:
			log.Warn("unknown control message", "type", msg.Type)
		}
	}
}

func (s *Server) handleMacSession(w http.ResponseWriter, r *http.Request) {
	macID, sessionID := r.PathValue("macID"), r.PathValue("sessionID")
	if !validID(sessionID) {
		http.Error(w, "invalid session id", http.StatusBadRequest)
		return
	}
	if !s.authenticateMac(w, r, macID, false) {
		return
	}
	// Claiming removes the entry, so a session can be answered exactly once and
	// a phone that timed out concurrently sees it as claimed and waits for us.
	s.mu.Lock()
	p := s.pending[sessionID]
	if p != nil && p.macID == macID {
		delete(s.pending, sessionID)
	} else {
		p = nil
	}
	s.mu.Unlock()
	if p == nil {
		http.Error(w, "unknown session", http.StatusNotFound)
		return
	}
	conn, err := s.accept(w, r)
	if err != nil {
		p.ready <- nil
		return
	}
	half := &macHalf{conn: conn, done: make(chan struct{})}
	p.ready <- half
	<-half.done
}

func (s *Server) handleConnect(w http.ResponseWriter, r *http.Request) {
	macID := r.PathValue("macID")
	if !validID(macID) {
		http.Error(w, "invalid mac id", http.StatusBadRequest)
		return
	}
	token, ok := bearer(r)
	if !ok {
		http.Error(w, "missing bearer token", http.StatusUnauthorized)
		return
	}
	if !s.store.TokenAllowed(macID, token) {
		http.Error(w, "not allowed", http.StatusForbidden)
		return
	}
	log := s.log.With("mac", idPrefix(macID))

	s.mu.Lock()
	online := s.macs[macID] != nil && s.macs[macID].control != nil
	s.mu.Unlock()
	if !online {
		http.Error(w, "mac offline", http.StatusNotFound)
		return
	}
	ip := clientIP(r)
	if !s.ipRate.allow(ip) || !s.macRate.allow(macID) {
		log.Warn("connect rate limited", "ip", ip)
		http.Error(w, "too many connects", http.StatusTooManyRequests)
		return
	}

	sessionID := newID()
	p := &pendingSession{macID: macID, ready: make(chan *macHalf, 1)}
	s.mu.Lock()
	st := s.macs[macID]
	control := st.control
	switch {
	case control == nil:
		s.mu.Unlock()
		http.Error(w, "mac offline", http.StatusNotFound)
		return
	case st.sessions >= s.cfg.MaxSessionsPerMac:
		s.mu.Unlock()
		log.Warn("session limit reached")
		http.Error(w, "too many sessions", http.StatusTooManyRequests)
		return
	}
	st.sessions++
	s.pending[sessionID] = p
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		st.sessions--
		delete(s.pending, sessionID)
		s.mu.Unlock()
	}()

	phone, err := s.accept(w, r)
	if err != nil {
		return
	}

	notice, _ := json.Marshal(map[string]string{"type": "incoming", "session": sessionID})
	wctx, cancel := context.WithTimeout(s.ctx, 5*time.Second)
	err = control.Write(wctx, websocket.MessageText, notice)
	cancel()
	if err != nil {
		phone.Close(StatusMacUnreachable, "mac unreachable")
		return
	}

	half, ok := s.awaitMac(sessionID, p)
	switch {
	case !ok && s.ctx.Err() != nil:
		phone.Close(websocket.StatusGoingAway, "relay shutting down")
		return
	case !ok:
		log.Info("mac did not answer session")
		phone.Close(StatusMacTimeout, "mac did not answer")
		return
	case half == nil:
		phone.Close(StatusMacUnreachable, "mac session failed")
		return
	}
	defer close(half.done)
	// Tracked only now: pings need a concurrent reader, which the pipe provides.
	defer s.track(phone)()
	defer s.track(half.conn)()

	log.Info("session started")
	start := time.Now()
	s.pipe(phone, half.conn)
	log.Info("session ended", "duration", time.Since(start).Round(time.Millisecond))
}

// awaitMac waits for the Mac's half. ok is false if the session timed out (or
// the relay is shutting down) before the Mac claimed it.
func (s *Server) awaitMac(sessionID string, p *pendingSession) (half *macHalf, ok bool) {
	timer := time.NewTimer(s.cfg.SessionTimeout)
	defer timer.Stop()
	select {
	case half = <-p.ready:
		return half, true
	case <-timer.C:
	case <-s.ctx.Done():
	}
	s.mu.Lock()
	_, unclaimed := s.pending[sessionID]
	delete(s.pending, sessionID)
	s.mu.Unlock()
	if unclaimed {
		return nil, false
	}
	// The Mac claimed it just now; its handler always delivers.
	return <-p.ready, true
}

// pipe forwards messages both ways until either side fails or closes, then
// closes both.
func (s *Server) pipe(a, b *websocket.Conn) {
	errc := make(chan error, 2)
	go func() { errc <- forward(a, b) }()
	go func() { errc <- forward(b, a) }()
	<-errc
	// Close both concurrently; Close on an already closed conn returns at once.
	var wg sync.WaitGroup
	for _, c := range []*websocket.Conn{a, b} {
		wg.Go(func() { c.Close(websocket.StatusNormalClosure, "peer closed") })
	}
	wg.Wait()
	<-errc
}

func forward(src, dst *websocket.Conn) error {
	ctx := context.Background()
	for {
		typ, data, err := src.Read(ctx)
		if err != nil {
			return err
		}
		if err := dst.Write(ctx, typ, data); err != nil {
			return err
		}
	}
}

func (s *Server) authenticateMac(w http.ResponseWriter, r *http.Request, macID string, register bool) bool {
	if !validID(macID) {
		http.Error(w, "invalid mac id", http.StatusBadRequest)
		return false
	}
	secret, ok := bearer(r)
	if !ok {
		http.Error(w, "missing bearer token", http.StatusUnauthorized)
		return false
	}
	ok, err := s.store.AuthenticateMac(macID, secret, register)
	if errors.Is(err, ErrStoreFull) {
		s.log.Error("relay store full; refusing a new mac")
		http.Error(w, "relay full", http.StatusServiceUnavailable)
		return false
	}
	if err != nil {
		s.log.Error("register mac", "mac", idPrefix(macID), "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return false
	}
	if !ok {
		s.log.Warn("mac authentication failed", "mac", idPrefix(macID))
		http.Error(w, "forbidden", http.StatusForbidden)
		return false
	}
	return true
}

func (s *Server) accept(w http.ResponseWriter, r *http.Request) (*websocket.Conn, error) {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{CompressionMode: websocket.CompressionDisabled})
	if err != nil {
		s.log.Warn("websocket upgrade failed", "err", err)
		return nil, err
	}
	conn.SetReadLimit(s.cfg.MaxMessageBytes)
	return conn, nil
}

// track keeps conn alive with pings, closes it on Shutdown, and counts it for
// Shutdown's wait. Pings need a concurrent reader, so call it only once conn
// is being read. The returned func releases it.
func (s *Server) track(conn *websocket.Conn) (release func()) {
	s.conns.Add(1)
	ctx, cancel := context.WithCancel(s.ctx)
	go s.keepalive(ctx, conn)
	stop := context.AfterFunc(s.ctx, func() { conn.Close(websocket.StatusGoingAway, "relay shutting down") })
	return func() {
		stop()
		cancel()
		s.conns.Done()
	}
}

func (s *Server) keepalive(ctx context.Context, conn *websocket.Conn) {
	t := time.NewTicker(s.cfg.PingInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			pctx, cancel := context.WithTimeout(ctx, s.cfg.PingInterval)
			err := conn.Ping(pctx)
			cancel()
			if err != nil {
				if ctx.Err() == nil {
					conn.CloseNow() // missed pong: drop it
				}
				return
			}
		}
	}
}

func (s *Server) mac(macID string) *macState {
	st := s.macs[macID]
	if st == nil {
		st = &macState{}
		s.macs[macID] = st
	}
	return st
}

// validID accepts 16 bytes encoded as base64url without padding (22 chars).
func validID(id string) bool {
	if len(id) != 22 {
		return false
	}
	b, err := base64.RawURLEncoding.Strict().DecodeString(id)
	return err == nil && len(b) == 16
}

func validTokenHashes(hashes []string) bool {
	if len(hashes) > maxTokenHashes {
		return false
	}
	for _, h := range hashes {
		b, err := base64.RawURLEncoding.Strict().DecodeString(h)
		if err != nil || len(b) != 32 {
			return false
		}
	}
	return true
}

func newID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b) // crypto/rand.Read never fails
	return base64.RawURLEncoding.EncodeToString(b)
}

func bearer(r *http.Request) (string, bool) {
	tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	tok = strings.TrimSpace(tok)
	return tok, ok && tok != ""
}

// clientIP trusts CF-Connecting-IP / X-Forwarded-For only from the local
// reverse proxy; anyone else could forge them.
func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {
		return host
	}
	if cf := strings.TrimSpace(r.Header.Get("CF-Connecting-IP")); cf != "" {
		return cf
	}
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		first, _, _ := strings.Cut(xff, ",")
		if first = strings.TrimSpace(first); first != "" {
			return first
		}
	}
	return host
}

// idPrefix is the only form of an identifier that reaches the logs.
func idPrefix(id string) string {
	if len(id) > 6 {
		return id[:6]
	}
	return id
}
