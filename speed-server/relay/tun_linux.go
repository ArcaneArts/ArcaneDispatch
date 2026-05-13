//go:build linux

package relay

import (
	"encoding/binary"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"syscall"
	"unsafe"
)

const (
	tunIfNameSize = 16
	tunSetIFF     = 0x400454ca
	tunIFFTun     = 0x0001
	tunIFFNoPI    = 0x1000
)

// TunPacketDevice bridges the relay to a Linux /dev/net/tun device.
type TunPacketDevice struct {
	file    *os.File
	packets chan []byte
	done    chan struct{}
	log     *slog.Logger
}

func NewTunPacketDevice(cfg TunConfig) (*TunPacketDevice, error) {
	if cfg.Name == "" {
		cfg.Name = "dispatch0"
	}
	if cfg.ServerIP == "" {
		cfg.ServerIP = "10.42.0.1"
	}
	if cfg.ClientIP == "" {
		cfg.ClientIP = "10.42.0.2"
	}
	if cfg.MTU == 0 {
		cfg.MTU = 1400
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}

	file, actualName, err := openTun(cfg.Name)
	if err != nil {
		return nil, err
	}
	device := &TunPacketDevice{
		file:    file,
		packets: make(chan []byte, 256),
		done:    make(chan struct{}),
		log:     cfg.Logger,
	}
	if cfg.Configure {
		if err := configureTun(actualName, cfg); err != nil {
			_ = device.Close()
			return nil, err
		}
	}
	go device.readLoop()
	cfg.Logger.Info("tun ready",
		slog.String("name", actualName),
		slog.String("server_ip", cfg.ServerIP),
		slog.String("client_ip", cfg.ClientIP),
		slog.Int("mtu", cfg.MTU))
	return device, nil
}

func openTun(name string) (*os.File, string, error) {
	file, err := os.OpenFile("/dev/net/tun", os.O_RDWR, 0)
	if err != nil {
		return nil, "", fmt.Errorf("open /dev/net/tun: %w", err)
	}

	var ifr [tunIfNameSize + 64]byte
	copy(ifr[:tunIfNameSize], []byte(name))
	binary.LittleEndian.PutUint16(ifr[tunIfNameSize:tunIfNameSize+2], tunIFFTun|tunIFFNoPI)
	_, _, errno := syscall.Syscall(
		syscall.SYS_IOCTL,
		file.Fd(),
		uintptr(tunSetIFF),
		uintptr(unsafe.Pointer(&ifr[0])),
	)
	if errno != 0 {
		_ = file.Close()
		return nil, "", fmt.Errorf("ioctl TUNSETIFF %s: %w", name, errno)
	}
	actual := string(ifr[:tunIfNameSize])
	for i, b := range ifr[:tunIfNameSize] {
		if b == 0 {
			actual = string(ifr[:i])
			break
		}
	}
	return file, actual, nil
}

func configureTun(name string, cfg TunConfig) error {
	commands := [][]string{
		{"ip", "addr", "flush", "dev", name},
		{"ip", "addr", "add", cfg.ServerIP, "peer", cfg.ClientIP, "dev", name},
		{"ip", "link", "set", "dev", name, "mtu", fmt.Sprintf("%d", cfg.MTU), "up"},
		{"sysctl", "-w", "net.ipv4.ip_forward=1"},
	}
	for _, command := range commands {
		if err := runTunCommand(cfg.Logger, command[0], command[1:]...); err != nil {
			return err
		}
	}
	check := exec.Command("iptables", "-t", "nat", "-C", "POSTROUTING", "-s", cfg.ClientIP+"/32", "-j", "MASQUERADE")
	if err := check.Run(); err == nil {
		return nil
	}
	return runTunCommand(cfg.Logger, "iptables",
		"-t", "nat", "-A", "POSTROUTING",
		"-s", cfg.ClientIP+"/32",
		"-j", "MASQUERADE")
}

func runTunCommand(log *slog.Logger, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %v: %w: %s", name, args, err, string(out))
	}
	if len(out) > 0 {
		log.Debug("tun command",
			slog.String("cmd", name),
			slog.Any("args", args),
			slog.String("out", string(out)))
	}
	return nil
}

func (d *TunPacketDevice) WritePacket(packet []byte) error {
	if d == nil || d.file == nil {
		return errors.New("tun device is closed")
	}
	_, err := d.file.Write(packet)
	return err
}

func (d *TunPacketDevice) Packets() <-chan []byte {
	return d.packets
}

func (d *TunPacketDevice) Close() error {
	if d == nil || d.file == nil {
		return nil
	}
	select {
	case <-d.done:
	default:
		close(d.done)
	}
	err := d.file.Close()
	d.file = nil
	return err
}

func (d *TunPacketDevice) readLoop() {
	defer close(d.packets)
	file := d.file
	buf := make([]byte, 65535)
	for {
		n, err := file.Read(buf)
		if err != nil {
			select {
			case <-d.done:
			default:
				d.log.Warn("tun read", slog.String("err", err.Error()))
			}
			return
		}
		packet := append([]byte(nil), buf[:n]...)
		select {
		case d.packets <- packet:
		case <-d.done:
			return
		}
	}
}
