package main

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/songgao/water"
)

const whitelistConfigPath = "/etc/ygg-exitd.conf"

type peerTable struct {
	mu      sync.RWMutex
	byInner map[string]*net.UDPAddr
}

type clientBindings struct {
	byYgg   map[string]net.IP
	byInner map[string]string
}

func normalizeIPv6(ip net.IP) (string, bool) {
	if ip == nil || ip.To4() != nil {
		return "", false
	}
	v6 := ip.To16()
	if v6 == nil {
		return "", false
	}
	return v6.String(), true
}

func normalizeIPv4(ip net.IP) (string, bool) {
	if ip == nil {
		return "", false
	}
	v4 := ip.To4()
	if v4 == nil {
		return "", false
	}
	return v4.String(), true
}

func newPeerTable() *peerTable {
	return &peerTable{
		byInner: make(map[string]*net.UDPAddr),
	}
}

func cloneUDPAddr(addr *net.UDPAddr) *net.UDPAddr {
	if addr == nil {
		return nil
	}
	return &net.UDPAddr{
		IP:   append(net.IP(nil), addr.IP...),
		Port: addr.Port,
		Zone: addr.Zone,
	}
}

func (p *peerTable) Set(innerIP net.IP, addr *net.UDPAddr) {
	if innerIP == nil || addr == nil {
		return
	}
	key := innerIP.String()
	if key == "" {
		return
	}

	p.mu.Lock()
	p.byInner[key] = cloneUDPAddr(addr)
	p.mu.Unlock()
}

func (p *peerTable) Get(innerIP net.IP) *net.UDPAddr {
	if innerIP == nil {
		return nil
	}

	p.mu.RLock()
	addr, ok := p.byInner[innerIP.String()]
	p.mu.RUnlock()
	if !ok {
		return nil
	}
	return cloneUDPAddr(addr)
}

func parsePacketIPs(pkt []byte) (srcIP net.IP, dstIP net.IP, ok bool) {
	if len(pkt) < 1 {
		return nil, nil, false
	}

	ver := pkt[0] >> 4
	switch ver {
	case 4:
		if len(pkt) < 20 {
			return nil, nil, false
		}
		ihl := int(pkt[0]&0x0f) * 4
		if ihl < 20 || len(pkt) < ihl {
			return nil, nil, false
		}
		src := net.IP(append([]byte(nil), pkt[12:16]...))
		dst := net.IP(append([]byte(nil), pkt[16:20]...))
		return src, dst, true
	case 6:
		if len(pkt) < 40 {
			return nil, nil, false
		}
		src := net.IP(append([]byte(nil), pkt[8:24]...))
		dst := net.IP(append([]byte(nil), pkt[24:40]...))
		return src, dst, true
	default:
		return nil, nil, false
	}
}

func run(cmd string, args ...string) error {
	c := exec.Command(cmd, args...)
	out, err := c.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %s failed: %w; output=%s", cmd, strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}

func ensureTun(name, cidr string, mtu int) (*water.Interface, error) {
	cfg := water.Config{
		DeviceType: water.TUN,
	}
	cfg.PlatformSpecificParams = water.PlatformSpecificParams{
		Name: name,
	}

	ifce, err := water.New(cfg)
	if err != nil {
		return nil, fmt.Errorf("create/open TUN failed: %w", err)
	}

	realName := ifce.Name()
	log.Printf("TUN device: %s", realName)

	if err := run("ip", "addr", "replace", cidr, "dev", realName); err != nil {
		_ = ifce.Close()
		return nil, err
	}
	if mtu > 0 {
		if err := run("ip", "link", "set", "dev", realName, "mtu", fmt.Sprintf("%d", mtu)); err != nil {
			_ = ifce.Close()
			return nil, err
		}
	}
	if err := run("ip", "link", "set", "dev", realName, "up"); err != nil {
		_ = ifce.Close()
		return nil, err
	}

	return ifce, nil
}

func isClosedConnErr(err error) bool {
	if err == nil {
		return false
	}
	s := err.Error()
	return strings.Contains(s, "use of closed network connection") ||
		strings.Contains(s, "file already closed")
}

func ensureWhitelistConfig(path string) error {
	if _, err := os.Stat(path); err == nil {
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("stat whitelist config failed: %w", err)
	}

	const defaultConfig = `# ygg-exitd whitelist
# Format: <client-yggdrasil-ipv6> <client-inner-ipv4>
# Example:
# 200:1111:2222:3333:4444:5555:6666:7777 10.66.0.10
`

	if err := os.WriteFile(path, []byte(defaultConfig), 0644); err != nil {
		return fmt.Errorf("create whitelist config failed: %w", err)
	}

	log.Printf("created empty whitelist config: %s", path)
	return nil
}

func loadWhitelist(path, tunCIDR string) (*clientBindings, error) {
	tunIP, tunNet, err := net.ParseCIDR(tunCIDR)
	if err != nil {
		return nil, fmt.Errorf("invalid --tun-cidr %q: %w", tunCIDR, err)
	}
	tunIP4 := tunIP.To4()
	if tunIP4 == nil {
		return nil, fmt.Errorf("invalid --tun-cidr %q: TUN IP must be IPv4", tunCIDR)
	}

	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open whitelist config failed: %w", err)
	}
	defer f.Close()

	bindings := &clientBindings{
		byYgg:   make(map[string]net.IP),
		byInner: make(map[string]string),
	}

	sc := bufio.NewScanner(f)
	lineNo := 0
	for sc.Scan() {
		lineNo++
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		fields := strings.Fields(line)
		if len(fields) != 2 {
			return nil, fmt.Errorf("invalid whitelist entry at %s:%d: expected '<client-yggdrasil-ipv6> <client-inner-ipv4>', got %q", path, lineNo, line)
		}

		yggIP := net.ParseIP(fields[0])
		yggKey, ok := normalizeIPv6(yggIP)
		if !ok {
			return nil, fmt.Errorf("invalid client Yggdrasil IPv6 at %s:%d: %q", path, lineNo, fields[0])
		}

		innerIP := net.ParseIP(fields[1])
		innerKey, ok := normalizeIPv4(innerIP)
		if !ok {
			return nil, fmt.Errorf("invalid client inner IPv4 at %s:%d: %q", path, lineNo, fields[1])
		}
		innerV4 := net.ParseIP(innerKey).To4()

		if !tunNet.Contains(innerV4) {
			return nil, fmt.Errorf("inner IPv4 %s at %s:%d is outside --tun-cidr %s", innerKey, path, lineNo, tunCIDR)
		}
		if innerV4.Equal(tunIP4) {
			return nil, fmt.Errorf("inner IPv4 %s at %s:%d must not be equal to TUN interface address", innerKey, path, lineNo)
		}
		if _, exists := bindings.byYgg[yggKey]; exists {
			return nil, fmt.Errorf("duplicate client Yggdrasil IPv6 %s at %s:%d", yggKey, path, lineNo)
		}
		if prevYgg, exists := bindings.byInner[innerKey]; exists {
			return nil, fmt.Errorf("duplicate client inner IPv4 %s at %s:%d (already used by %s)", innerKey, path, lineNo, prevYgg)
		}

		bindings.byYgg[yggKey] = append(net.IP(nil), innerV4...)
		bindings.byInner[innerKey] = yggKey
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("read whitelist config failed: %w", err)
	}

	return bindings, nil
}

func packetAllowedForClient(addrIP net.IP, pkt []byte, bindings *clientBindings) (net.IP, bool) {
	if bindings == nil {
		return nil, false
	}

	yggKey, ok := normalizeIPv6(addrIP)
	if !ok {
		return nil, false
	}

	expectedInner, ok := bindings.byYgg[yggKey]
	if !ok {
		return nil, false
	}

	srcIP, _, ok := parsePacketIPs(pkt)
	if !ok {
		return nil, false
	}

	srcV4 := srcIP.To4()
	if srcV4 == nil {
		return nil, false
	}
	if !srcV4.Equal(expectedInner) {
		return nil, false
	}

	return append(net.IP(nil), expectedInner...), true
}

func main() {
	var listenAddr string
	var tunName string
	var tunCIDR string
	var tunMTU int

	flag.StringVar(&listenAddr, "listen", "", "UDP listen address, e.g. [200:xxxx:....]:40001")
	flag.StringVar(&tunName, "tun-name", "yggexit0", "TUN interface name")
	flag.StringVar(&tunCIDR, "tun-cidr", "10.66.0.1/24", "CIDR address for TUN")
	flag.IntVar(&tunMTU, "tun-mtu", 1280, "MTU for TUN interface")
	flag.Parse()

	if listenAddr == "" {
		log.Fatal("missing --listen")
	}

	if os.Geteuid() != 0 {
		log.Fatal("run as root")
	}

	if err := ensureWhitelistConfig(whitelistConfigPath); err != nil {
		log.Fatalf("whitelist config setup failed: %v", err)
	}
	whitelist, err := loadWhitelist(whitelistConfigPath, tunCIDR)
	if err != nil {
		log.Fatalf("whitelist config load failed: %v", err)
	}
	log.Printf("whitelist loaded: %d client(s)", len(whitelist.byYgg))

	ifce, err := ensureTun(tunName, tunCIDR, tunMTU)
	if err != nil {
		log.Fatalf("TUN setup failed: %v", err)
	}
	defer ifce.Close()

	udpAddr, err := net.ResolveUDPAddr("udp6", listenAddr)
	if err != nil {
		log.Fatalf("resolve listen addr failed: %v", err)
	}

	conn, err := net.ListenUDP("udp6", udpAddr)
	if err != nil {
		log.Fatalf("listen UDP failed: %v", err)
	}
	defer conn.Close()

	log.Printf("listening on %s", conn.LocalAddr().String())

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	peerByInnerIP := newPeerTable()
	errCh := make(chan error, 2)

	// UDP -> TUN
	go func() {
		buf := make([]byte, 65535)
		for {
			_ = conn.SetReadDeadline(time.Now().Add(1 * time.Second))
			n, addr, err := conn.ReadFromUDP(buf)
			if err != nil {
				if isClosedConnErr(err) {
					return
				}
				if ne, ok := err.(net.Error); ok && ne.Timeout() {
					select {
					case <-ctx.Done():
						return
					default:
						continue
					}
				}
				errCh <- fmt.Errorf("udp read failed: %w", err)
				return
			}
			if n == 0 {
				continue
			}

			addrIP := addr.IP
			if _, ok := normalizeIPv6(addrIP); !ok {
				log.Printf("ignoring non-IPv6 client %s", addr.String())
				continue
			}

			assignedInner, ok := packetAllowedForClient(addrIP, buf[:n], whitelist)
			if !ok {
				log.Printf("ignoring packet from %s: client not allowed or source inner IP mismatch", addr.String())
				continue
			}

			peerByInnerIP.Set(assignedInner, addr)

			_, err = ifce.Write(buf[:n])
			if err != nil {
				if errors.Is(err, os.ErrClosed) {
					return
				}
				errCh <- fmt.Errorf("write to TUN failed: %w", err)
				return
			}
		}
	}()

	// TUN -> UDP
	go func() {
		buf := make([]byte, 65535)
		for {
			n, err := ifce.Read(buf)
			if err != nil {
				if errors.Is(err, os.ErrClosed) {
					return
				}
				select {
				case <-ctx.Done():
					return
				default:
				}
				errCh <- fmt.Errorf("read from TUN failed: %w", err)
				return
			}
			if n == 0 {
				continue
			}

			_, dstIP, ok := parsePacketIPs(buf[:n])
			if !ok {
				log.Printf("ignoring malformed packet from TUN")
				continue
			}

			peer := peerByInnerIP.Get(dstIP)
			if peer == nil {
				// Неизвестный получатель: в таблице нет соответствия
				// внутреннего dst IP -> клиент UDP endpoint.
				continue
			}

			_, err = conn.WriteToUDP(buf[:n], peer)
			if err != nil {
				if isClosedConnErr(err) {
					return
				}
				errCh <- fmt.Errorf("udp write failed: %w", err)
				return
			}
		}
	}()

	select {
	case <-ctx.Done():
		log.Printf("shutting down")
	case err := <-errCh:
		log.Printf("fatal: %v", err)
	}

	_ = conn.Close()
	_ = ifce.Close()
	time.Sleep(100 * time.Millisecond)
}
