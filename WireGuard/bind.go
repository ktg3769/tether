package main

import (
	"net"
	"net/netip"
	"sync"
	"sync/atomic"
	"time"

	"golang.zx2c4.com/wireguard/conn"
)

// hostBind is a conn.Bind that listens on one address only, the hotspot's.
// wireguard-go's own bind listens on every interface.
type hostBind struct {
	host netip.Addr
	mu   sync.Mutex
	c    *net.UDPConn
}

// bindStats count what reaches the UDP port and what can't be sent back, for the diagnostics
// screen: none in says the device's packets never reach the iPhone, send failures say the replies
// can't leave (Local Network permission, for one).
var bindStats struct {
	in, sendFailed atomic.Uint64
	lastFrom       atomic.Pointer[string]
	lastSendError  atomic.Pointer[string]
}

type endpoint struct{ netip.AddrPort }

func (e endpoint) ClearSrc()           {}
func (e endpoint) SrcToString() string { return "" }
func (e endpoint) DstToString() string { return e.AddrPort.String() }
func (e endpoint) DstToBytes() []byte  { b, _ := e.AddrPort.MarshalBinary(); return b }
func (e endpoint) DstIP() netip.Addr   { return e.AddrPort.Addr() }
func (e endpoint) SrcIP() netip.Addr   { return netip.Addr{} }

func (b *hostBind) Open(port uint16) ([]conn.ReceiveFunc, uint16, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.c != nil {
		return nil, 0, conn.ErrBindAlreadyOpen
	}
	c, err := net.ListenUDP("udp", net.UDPAddrFromAddrPort(netip.AddrPortFrom(b.host, port)))
	if err != nil {
		return nil, 0, err
	}
	b.c = c
	receive := func(packets [][]byte, sizes []int, eps []conn.Endpoint) (int, error) {
		n, from, err := c.ReadFromUDPAddrPort(packets[0])
		if err != nil {
			return 0, err
		}
		sizes[0] = n
		eps[0] = endpoint{netip.AddrPortFrom(from.Addr().Unmap(), from.Port())}
		bindStats.in.Add(1)
		f := from.String()
		bindStats.lastFrom.Store(&f)
		return 1, nil
	}
	return []conn.ReceiveFunc{receive}, uint16(c.LocalAddr().(*net.UDPAddr).Port), nil
}

func (b *hostBind) Close() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.c == nil {
		return nil
	}
	err := b.c.Close()
	b.c = nil
	return err
}

func (b *hostBind) Send(bufs [][]byte, ep conn.Endpoint) error {
	b.mu.Lock()
	c := b.c
	b.mu.Unlock()
	if c == nil {
		return net.ErrClosed
	}
	e, ok := ep.(endpoint)
	if !ok {
		return conn.ErrWrongEndpointType
	}
	for _, buf := range bufs {
		if _, err := c.WriteToUDPAddrPort(buf, e.AddrPort); err != nil {
			bindStats.sendFailed.Add(1)
			m := time.Now().Format("15:04:05") + " to " + e.AddrPort.String() + ": " + err.Error()
			bindStats.lastSendError.Store(&m)
			return err
		}
	}
	return nil
}

func (b *hostBind) ParseEndpoint(s string) (conn.Endpoint, error) {
	ap, err := netip.ParseAddrPort(s)
	return endpoint{ap}, err
}

func (b *hostBind) SetMark(uint32) error { return nil }
func (b *hostBind) BatchSize() int       { return 1 }
