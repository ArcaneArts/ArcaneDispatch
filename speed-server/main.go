// Package main hosts the dispatch-speed-server CLI.
//
// This is the reference implementation of the Speed Server side of the
// ArcaneDispatch bonded transport. The protocol lives in `bonded/` and is
// a literal port of `lib/bonded/bonded_framing.dart` and
// `lib/bonded/bonded_reassembler.dart`. Subcommands are documented inline.
//
// Status: Phase 8 of `plans/2026-05-11-speedify-clone-v1.md`. The current
// build provides:
//
//   * `genkey`  — generate a fresh server ed25519 keypair on disk
//   * `adduser` — append a client token to the auth store
//   * `serve`   — start the UDP relay (TCP/TLS land in Phase 11)
//   * `stats`   — print Prometheus-style counters from the live process
//
// We deliberately keep this layer dependency-free beyond the Go standard
// library; cgo'd crypto primitives land in Phase 9 alongside the real
// Noise IK handshake.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"art.arcane/dispatch-speed-server/auth"
	"art.arcane/dispatch-speed-server/relay"
)

const usage = `dispatch-speed-server — bonded transport relay

Usage:
  dispatch-speed-server <command> [flags]

Commands:
  serve    Start the bonded relay (UDP + TCP).
  genkey   Generate an ed25519 server keypair at -out path.
  adduser  Append a client token to the auth store.
  stats    Print live counters from a running server.

Run "dispatch-speed-server <command> -h" for command-specific flags.
`

// main dispatches to the requested subcommand. We hand-roll the dispatch so
// every subcommand owns its own `flag.FlagSet`, which keeps usage strings
// scoped and lets callers invoke `--help` per subcommand without the global
// flag soup that `flag` ends up with.
func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	cmd := os.Args[1]
	args := os.Args[2:]
	switch cmd {
	case "serve":
		os.Exit(runServe(args))
	case "genkey":
		os.Exit(runGenkey(args))
	case "adduser":
		os.Exit(runAdduser(args))
	case "stats":
		os.Exit(runStats(args))
	case "-h", "--help", "help":
		fmt.Print(usage)
		os.Exit(0)
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n\n%s", cmd, usage)
		os.Exit(2)
	}
}

// runServe boots the bonded UDP relay and (optionally) the TCP / TLS
// fallback relays added in Phase 11. Each transport is bound to its own
// flag so operators can pick which fallbacks to enable; passing
// `-tcp ""` or `-tls ""` disables the respective listener.
func runServe(args []string) int {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	udpAddr := fs.String("udp", ":4430", "UDP listen address for bonded frames (\"\" to disable)")
	tcpAddr := fs.String("tcp", "", "TCP listen address for bonded frames (\"\" to disable)")
	tlsAddr := fs.String("tls", "", "TLS-on-443 listen address (HTTP/1.1 Upgrade) (\"\" to disable)")
	tlsCert := fs.String("tls-cert", "", "Path to PEM-encoded server certificate (required with -tls)")
	tlsKey := fs.String("tls-key", "", "Path to PEM-encoded private key (required with -tls)")
	statsAddr := fs.String("stats", ":9090", "HTTP listen address for /stats")
	authPath := fs.String("auth", "./auth.json", "Path to the auth store JSON (Phase 9)")
	keyPath := fs.String("key", "./server.key", "Path to the server key file (Phase 9)")
	idle := fs.Duration("idle-timeout", 5*time.Minute, "Reap sessions idle longer than this")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	log.Info("serve starting",
		slog.String("udp", *udpAddr),
		slog.String("tcp", *tcpAddr),
		slog.String("tls", *tlsAddr),
		slog.String("stats", *statsAddr),
		slog.String("auth", *authPath),
		slog.String("key", *keyPath))

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var udp *relay.UDPRelay
	if *udpAddr != "" {
		udp = relay.NewUDPRelay(relay.UDPRelayConfig{
			ListenAddr:         *udpAddr,
			SessionIdleTimeout: *idle,
			Logger:             log,
		})
		if err := udp.Start(ctx); err != nil {
			log.Error("udp relay start", slog.String("err", err.Error()))
			return 1
		}
		defer udp.Stop()
	}

	var tcp *relay.TCPRelay
	if *tcpAddr != "" {
		tcp = relay.NewTCPRelay(relay.TCPRelayConfig{
			ListenAddr:         *tcpAddr,
			SessionIdleTimeout: *idle,
			Logger:             log,
		})
		if err := tcp.Start(ctx); err != nil {
			log.Error("tcp relay start", slog.String("err", err.Error()))
			return 1
		}
		defer tcp.Stop()
	}

	var tlsR *relay.TLSRelay
	if *tlsAddr != "" {
		if *tlsCert == "" || *tlsKey == "" {
			log.Error("tls relay requires -tls-cert and -tls-key")
			return 2
		}
		certPEM, err := os.ReadFile(*tlsCert)
		if err != nil {
			log.Error("read cert", slog.String("err", err.Error()))
			return 1
		}
		keyPEM, err := os.ReadFile(*tlsKey)
		if err != nil {
			log.Error("read key", slog.String("err", err.Error()))
			return 1
		}
		tlsR = relay.NewTLSRelay(relay.TLSRelayConfig{
			TCPRelayConfig: relay.TCPRelayConfig{
				ListenAddr:         *tlsAddr,
				SessionIdleTimeout: *idle,
				Logger:             log,
			},
			CertPEM: certPEM,
			KeyPEM:  keyPEM,
		})
		if _, err := tlsR.Start(ctx); err != nil {
			log.Error("tls relay start", slog.String("err", err.Error()))
			return 1
		}
		defer tlsR.Stop()
	}

	if udp == nil && tcp == nil && tlsR == nil {
		log.Error("no relays enabled (set -udp, -tcp, or -tls)")
		return 2
	}

	statsSrv := startStatsServer(*statsAddr, udp, tcp, tlsR, log)
	defer func() {
		shutCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = statsSrv.Shutdown(shutCtx)
	}()

	<-ctx.Done()
	log.Info("serve shutting down")
	return 0
}

// startStatsServer hosts a single Prometheus-style endpoint that scrapes
// the relay counters across every enabled transport. We intentionally
// avoid the prometheus client lib — the surface is small enough that
// hand-written text format is cheaper than a third-party dep.
func startStatsServer(addr string, udp *relay.UDPRelay, tcp *relay.TCPRelay, tlsR *relay.TLSRelay, log *slog.Logger) *http.Server {
	mux := http.NewServeMux()
	mux.HandleFunc("/stats", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		fmt.Fprintf(w, "# HELP dispatch_packets_in Total bonded packets received.\n")
		fmt.Fprintf(w, "# TYPE dispatch_packets_in counter\n")
		if udp != nil {
			s := udp.Snapshot()
			fmt.Fprintf(w, "dispatch_packets_in{transport=\"udp\"} %d\n", s.PacketsIn)
			fmt.Fprintf(w, "dispatch_packets_bad{transport=\"udp\"} %d\n", s.PacketsBad)
			fmt.Fprintf(w, "dispatch_packets_accepted{transport=\"udp\"} %d\n", s.PacketsAccepted)
			fmt.Fprintf(w, "dispatch_bytes_in{transport=\"udp\"} %d\n", s.BytesIn)
			fmt.Fprintf(w, "dispatch_bytes_egress{transport=\"udp\"} %d\n", s.BytesEgress)
			fmt.Fprintf(w, "dispatch_naks{transport=\"udp\"} %d\n", s.Naks)
			fmt.Fprintf(w, "dispatch_sessions{transport=\"udp\"} %d\n", s.Sessions)
		}
		if tcp != nil {
			s := tcp.Snapshot()
			fmt.Fprintf(w, "dispatch_packets_in{transport=\"tcp\"} %d\n", s.PacketsIn)
			fmt.Fprintf(w, "dispatch_packets_bad{transport=\"tcp\"} %d\n", s.PacketsBad)
			fmt.Fprintf(w, "dispatch_packets_accepted{transport=\"tcp\"} %d\n", s.PacketsAccepted)
			fmt.Fprintf(w, "dispatch_bytes_in{transport=\"tcp\"} %d\n", s.BytesIn)
			fmt.Fprintf(w, "dispatch_bytes_egress{transport=\"tcp\"} %d\n", s.BytesEgress)
			fmt.Fprintf(w, "dispatch_connections{transport=\"tcp\"} %d\n", s.Connections)
			fmt.Fprintf(w, "dispatch_sessions{transport=\"tcp\"} %d\n", s.Sessions)
		}
		if tlsR != nil {
			s := tlsR.Snapshot()
			fmt.Fprintf(w, "dispatch_packets_in{transport=\"tls\"} %d\n", s.PacketsIn)
			fmt.Fprintf(w, "dispatch_packets_bad{transport=\"tls\"} %d\n", s.PacketsBad)
			fmt.Fprintf(w, "dispatch_packets_accepted{transport=\"tls\"} %d\n", s.PacketsAccepted)
			fmt.Fprintf(w, "dispatch_bytes_in{transport=\"tls\"} %d\n", s.BytesIn)
			fmt.Fprintf(w, "dispatch_bytes_egress{transport=\"tls\"} %d\n", s.BytesEgress)
			fmt.Fprintf(w, "dispatch_connections{transport=\"tls\"} %d\n", s.Connections)
			fmt.Fprintf(w, "dispatch_upgrade_rejected{transport=\"tls\"} %d\n", s.UpgradeRejected)
			fmt.Fprintf(w, "dispatch_sessions{transport=\"tls\"} %d\n", s.Sessions)
		}
	})
	srv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 2 * time.Second}
	go func() {
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Warn("stats server", slog.String("err", err.Error()))
		}
	}()
	return srv
}

// runGenkey writes a fresh ed25519 private key to `-out`. Refuses to
// overwrite by default; `-force` is the escape hatch. Public key is
// printed to stdout so operators can paste it into client config.
func runGenkey(args []string) int {
	fs := flag.NewFlagSet("genkey", flag.ExitOnError)
	out := fs.String("out", "./server.key", "Output path for the ed25519 private key")
	force := fs.Bool("force", false, "Overwrite an existing key file")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	priv, err := auth.GenerateKey(*out, *force)
	if err != nil {
		fmt.Fprintf(os.Stderr, "genkey: %v\n", err)
		return 1
	}
	fmt.Fprintf(os.Stderr, "wrote %s (chmod 0600)\n", *out)
	fmt.Printf("public-key: %s\n", auth.PublicKeyBase64(priv))
	return 0
}

// runAdduser appends a user with a freshly minted bearer token to the
// auth store, prints the token to stdout, and persists the store. The
// token is shown exactly once — losing it means rotating the user.
func runAdduser(args []string) int {
	fs := flag.NewFlagSet("adduser", flag.ExitOnError)
	authPath := fs.String("auth", "./auth.json", "Path to the auth store JSON")
	user := fs.String("user", "", "Username (label)")
	jsonOut := fs.Bool("json", false, "Print the new user as JSON instead of plain text")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *user == "" {
		fmt.Fprintln(os.Stderr, "adduser: -user is required")
		return 2
	}
	m, err := auth.OpenManager(*authPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "adduser: %v\n", err)
		return 1
	}
	u, err := m.AddUser(*user)
	if err != nil {
		fmt.Fprintf(os.Stderr, "adduser: %v\n", err)
		return 1
	}
	if *jsonOut {
		_ = json.NewEncoder(os.Stdout).Encode(u)
	} else {
		fmt.Printf("user=%s token=%s\n", u.Name, u.Token)
	}
	return 0
}

// runStats fetches the `/stats` endpoint from a running server and pipes
// the body to stdout. Useful in deploy probes (`docker exec dispatch
// stats`) and CI smoke tests.
func runStats(args []string) int {
	fs := flag.NewFlagSet("stats", flag.ExitOnError)
	statsAddr := fs.String("addr", "http://127.0.0.1:9090/stats", "Stats endpoint URL")
	timeout := fs.Duration("timeout", 3*time.Second, "HTTP timeout")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	client := &http.Client{Timeout: *timeout}
	resp, err := client.Get(*statsAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "stats: %v\n", err)
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		fmt.Fprintf(os.Stderr, "stats: HTTP %d from %s\n", resp.StatusCode, *statsAddr)
		return 1
	}
	if _, err := io.Copy(os.Stdout, resp.Body); err != nil {
		fmt.Fprintf(os.Stderr, "stats: %v\n", err)
		return 1
	}
	return 0
}
