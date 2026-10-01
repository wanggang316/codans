// Command codans-relay runs the codans relay (protocol v1) as plain HTTP/ws;
// a reverse proxy in front of it terminates TLS.
package main

import (
	"context"
	"errors"
	"flag"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"codans.dev/relay/internal/relay"
)

func main() {
	listen := flag.String("listen", envOr("CODANS_RELAY_LISTEN", "127.0.0.1:3050"), "listen address (env CODANS_RELAY_LISTEN)")
	dataDir := flag.String("data", envOr("CODANS_RELAY_DATA", "./data"), "data directory (env CODANS_RELAY_DATA)")
	flag.Parse()

	log := slog.New(slog.NewJSONHandler(os.Stderr, nil))
	slog.SetDefault(log)
	if err := run(*listen, *dataDir, log); err != nil {
		log.Error("relay stopped", "err", err)
		os.Exit(1)
	}
}

func run(listen, dataDir string, log *slog.Logger) error {
	store, err := relay.OpenStore(dataDir)
	if err != nil {
		return err
	}
	rs := relay.NewServer(store, relay.Config{Logger: log})
	srv := &http.Server{
		Addr:              listen,
		Handler:           rs,
		ReadHeaderTimeout: 10 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()

	errc := make(chan error, 1)
	go func() { errc <- srv.ListenAndServe() }()
	log.Info("relay listening", "addr", listen, "data", dataDir)

	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}
	log.Info("shutting down")
	sctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	// WebSockets are hijacked, so http.Server.Shutdown does not see them.
	if err := rs.Shutdown(sctx); err != nil {
		log.Warn("websocket shutdown incomplete", "err", err)
	}
	if err := srv.Shutdown(sctx); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
