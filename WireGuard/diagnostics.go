package main

import (
	"fmt"
	"net/netip"
	"sync/atomic"
	"time"
)

// diagnostics are counters for Tether's diagnostics screen, which tells where a device's traffic
// stops: never reaching the tunnel, dropped by wireguard-go, or failing on the iPhone's way out.
type diagnostics struct {
	invalid    atomic.Uint64 // WireGuard messages wireguard-go turned away: an unknown key, for one
	disallowed atomic.Uint64 // packets wireguard-go dropped for a source address the device doesn't have
	tcpTried   atomic.Uint64 // TCP connections the devices opened
	tcpFailed  atomic.Uint64 // of those, the ones the iPhone couldn't make
	udpFailed  atomic.Uint64 // UDP packets the iPhone couldn't send on
	lastError  atomic.Pointer[string]
}

func (d *diagnostics) fail(what string) {
	s := time.Now().Format("15:04:05") + " " + what
	d.lastError.Store(&s)
}

// diagMessage is the "diag" object in statsMessage.
type diagMessage struct {
	UDPIn      uint64 `json:"udpIn"`
	UDPFrom    string `json:"udpFrom"`
	SendFailed uint64 `json:"sendFailed"`
	SendError  string `json:"sendError"`
	Invalid    uint64 `json:"invalid"`
	Received   uint64 `json:"received"`
	LastIn     string `json:"lastIn"`
	Disallowed uint64 `json:"disallowed"`
	TCPTried   uint64 `json:"tcpTried"`
	TCPFailed  uint64 `json:"tcpFailed"`
	UDPFailed  uint64 `json:"udpFailed"`
	LastError  string `json:"lastError"`
	NAT64      string `json:"nat64"`
}

func (s *Server) diagMessage() diagMessage {
	m := diagMessage{
		UDPIn:      bindStats.in.Load(),
		SendFailed: bindStats.sendFailed.Load(),
		Invalid:    s.diag.invalid.Load(),
		Disallowed: s.diag.disallowed.Load(),
		TCPTried:   s.diag.tcpTried.Load(),
		TCPFailed:  s.diag.tcpFailed.Load(),
		UDPFailed:  s.diag.udpFailed.Load(),
	}
	if s.tun != nil {
		m.Received = s.tun.received.Load()
		if p := s.tun.lastIn.Load(); p != nil {
			m.LastIn = *p
		}
	}
	if p := bindStats.lastFrom.Load(); p != nil {
		m.UDPFrom = *p
	}
	if p := bindStats.lastSendError.Load(); p != nil {
		m.SendError = *p
	}
	if p := s.diag.lastError.Load(); p != nil {
		m.LastError = *p
	}
	if p := s.nat64.found.Load(); p != nil {
		m.NAT64 = p.String()
	}
	return m
}

// describePacket is "TCP 10.7.0.2 → 1.1.1.1:443" for an IP packet, or "" when it can't be read.
func describePacket(p []byte) string {
	if len(p) < 1 {
		return ""
	}
	var proto byte
	var src, dst string
	var rest []byte
	switch p[0] >> 4 {
	case 4:
		ihl := int(p[0]&0x0f) * 4
		if len(p) < 20 || len(p) < ihl {
			return ""
		}
		proto = p[9]
		src = fmt.Sprintf("%d.%d.%d.%d", p[12], p[13], p[14], p[15])
		dst = fmt.Sprintf("%d.%d.%d.%d", p[16], p[17], p[18], p[19])
		rest = p[ihl:]
	case 6:
		if len(p) < 40 {
			return ""
		}
		proto = p[6]
		src = ipv6String(p[8:24])
		dst = ipv6String(p[24:40])
		rest = p[40:]
	default:
		return fmt.Sprintf("not IP (first byte %#x)", p[0])
	}
	name := fmt.Sprintf("proto %d", proto)
	switch proto {
	case 6:
		name = "TCP"
	case 17:
		name = "UDP"
	case 1, 58:
		name = "ICMP"
	}
	if (proto == 6 || proto == 17) && len(rest) >= 4 {
		port := int(rest[2])<<8 | int(rest[3])
		if p[0]>>4 == 6 {
			dst = "[" + dst + "]"
		}
		return fmt.Sprintf("%s %s → %s:%d", name, src, dst, port)
	}
	return fmt.Sprintf("%s %s → %s", name, src, dst)
}

func ipv6String(b []byte) string {
	var a [16]byte
	copy(a[:], b)
	return netip.AddrFrom16(a).String()
}
