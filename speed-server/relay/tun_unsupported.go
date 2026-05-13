//go:build !linux

package relay

import (
	"errors"
)

type TunPacketDevice struct{}

func NewTunPacketDevice(TunConfig) (*TunPacketDevice, error) {
	return nil, errors.New("linux TUN packet device is only available on Linux")
}

func (d *TunPacketDevice) WritePacket([]byte) error {
	return errors.New("linux TUN packet device is only available on Linux")
}

func (d *TunPacketDevice) Packets() <-chan []byte {
	ch := make(chan []byte)
	close(ch)
	return ch
}

func (d *TunPacketDevice) Close() error {
	return nil
}
