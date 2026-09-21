// Wonder uses the owner's installed Tailscale client. It never creates a VPN
// identity or enables Funnel. Only --configure changes one unused HTTPS port.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const target = "http://127.0.0.1:3777"

type status struct {
	State  string `json:"state"`
	Origin string `json:"origin,omitempty"`
	Error  string `json:"error,omitempty"`
}
type serveConfig struct {
	TCP map[string]struct {
		HTTPS        bool
		TCPForward   string
		TerminateTLS string
	}
	Web map[string]struct {
		Handlers map[string]struct {
			Proxy string
			Path  string
			Text  string
		}
	}
	AllowFunnel map[string]bool
	Foreground  map[string]json.RawMessage
}
type runner func(...string) ([]byte, error)

func cliPath() string {
	if path := os.Getenv("WONDER_TAILSCALE_BIN"); path != "" {
		return path
	}
	for _, path := range []string{"/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"} {
		if info, err := os.Stat(path); err == nil && info.Mode().Perm()&0111 != 0 {
			return path
		}
	}
	return ""
}
func runCLI(path string) runner {
	return func(args ...string) ([]byte, error) {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		return exec.CommandContext(ctx, path, args...).CombinedOutput()
	}
}

// Ignore other ports, but fail closed on an occupied/public Wonder endpoint.
func configured(raw []byte, host, port string) (bool, error) {
	var config serveConfig
	if err := json.Unmarshal(raw, &config); err != nil {
		return false, fmt.Errorf("Tailscale returned an unreadable Serve configuration. Update Tailscale and retry.")
	}
	key := net.JoinHostPort(host, port)
	for endpoint, enabled := range config.AllowFunnel {
		_, p, err := net.SplitHostPort(endpoint)
		if enabled && err == nil && p == port {
			return false, fmt.Errorf("Port %s has public Funnel access. Disable Funnel on this port in Tailscale before connecting Wonder.", port)
		}
	}
	for _, foreground := range config.Foreground {
		var fg serveConfig
		if json.Unmarshal(foreground, &fg) != nil {
			return false, fmt.Errorf("Cannot verify a foreground Tailscale service. Stop that service and retry.")
		}
		if _, exists := fg.TCP[port]; exists {
			return false, fmt.Errorf("Port %s is used by a foreground Tailscale service. Choose another Wonder port.", port)
		}
	}
	tcp, exists := config.TCP[port]
	web, hasWeb := config.Web[key]
	handler, hasRoot := web.Handlers["/"]
	if exists && tcp.HTTPS && tcp.TCPForward == "" && tcp.TerminateTLS == "" && hasRoot && handler.Proxy == target && handler.Path == "" && handler.Text == "" {
		return true, nil
	}
	if exists || hasWeb {
		return false, fmt.Errorf("Tailscale port %s is already configured for another service. Wonder left it unchanged. Set WONDER_TAILSCALE_PORT to an unused HTTPS port.", port)
	}
	// The same port under an old DNS name must not be overwritten either.
	for endpoint := range config.Web {
		_, p, err := net.SplitHostPort(endpoint)
		if err == nil && p == port {
			return false, fmt.Errorf("Tailscale port %s is already in use. Its configuration was left unchanged.", port)
		}
	}
	return false, nil
}
func inspect(run runner, port string, configure bool) status {
	raw, err := run("status", "--json")
	if err != nil {
		return status{State: "unavailable", Error: "Open Tailscale and connect this Mac to your tailnet, then retry."}
	}
	var node struct {
		BackendState string
		Self         *struct{ DNSName string }
	}
	if json.Unmarshal(raw, &node) != nil {
		return status{State: "error", Error: "Tailscale status could not be read. Update Tailscale and retry."}
	}
	if node.BackendState != "Running" || node.Self == nil {
		return status{State: "auth_required", Error: "Open Tailscale and sign in. Connect your Mac and phone to the same tailnet."}
	}
	host := strings.TrimSuffix(node.Self.DNSName, ".")
	if !strings.HasSuffix(host, ".ts.net") || strings.ContainsAny(host, "/:@ ") {
		return status{State: "error", Error: "Enable MagicDNS and HTTPS certificates in your Tailscale admin console, then retry."}
	}
	raw, err = run("serve", "status", "--json")
	if err != nil {
		return status{State: "error", Error: "Tailscale Serve status is unavailable. Update Tailscale and retry."}
	}
	ready, err := configured(raw, host, port)
	if err != nil {
		return status{State: "error", Error: err.Error()}
	}
	if !ready && !configure {
		return status{State: "setup_required", Error: "Choose Enable private connection to set up Tailscale Serve."}
	}
	if !ready {
		// Never reset config; never pass Funnel or a whole replacement document.
		output, err := run("serve", "--bg", "--yes", "--https="+port, target)
		if err != nil {
			detail := strings.TrimSpace(string(output))
			if len(detail) > 1500 {
				detail = detail[:1500]
			}
			return status{State: "error", Error: "Tailscale Serve needs attention. Enable HTTPS certificates in your tailnet and retry. " + detail}
		}
		raw, err = run("serve", "status", "--json")
		if err != nil {
			return status{State: "error", Error: "Serve was requested but could not be verified. Retry the connection check."}
		}
		ready, err = configured(raw, host, port)
		if err != nil {
			return status{State: "error", Error: err.Error()}
		}
		if !ready {
			return status{State: "error", Error: "Tailscale did not retain Wonder's private endpoint. Retry the connection check."}
		}
	}
	return status{State: "ready", Origin: "https://" + net.JoinHostPort(host, port)}
}
func main() {
	configure := flag.Bool("configure", false, "configure one private Serve endpoint")
	once := flag.Bool("once", false, "inspect without monitoring")
	port := flag.String("port", os.Getenv("WONDER_TAILSCALE_PORT"), "unused private HTTPS port (default 8443)")
	flag.Parse()
	if *port == "" {
		*port = "8443"
	}
	n, err := strconv.Atoi(*port)
	if err != nil || n < 1024 || n > 65535 {
		emit(status{State: "error", Error: "Choose an HTTPS port between 1024 and 65535."})
		os.Exit(2)
	}
	path := cliPath()
	if path == "" {
		emit(status{State: "missing", Error: "Install Tailscale on this Mac and your phone, then connect them to the same tailnet."})
		os.Exit(1)
	}
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	previous := status{}
	for {
		current := inspect(runCLI(path), *port, *configure)
		if current != previous {
			emit(current)
			previous = current
		}
		if *configure || *once {
			if current.State != "ready" {
				os.Exit(1)
			}
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(5 * time.Second):
		}
	}
}
func emit(value status) { _ = json.NewEncoder(os.Stdout).Encode(value) }
