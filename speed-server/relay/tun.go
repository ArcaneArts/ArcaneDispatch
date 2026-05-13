package relay

import "log/slog"

// TunConfig describes the Linux TUN device used by the relay in production.
// Non-Linux builds return a clear unsupported error from NewTunPacketDevice.
type TunConfig struct {
	Name      string
	ServerIP  string
	ClientIP  string
	MTU       int
	Configure bool
	Logger    *slog.Logger
}
