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
# One allowed client IPv6 address per line.
# Example:
# 200:1111:2222:3333:4444:5555:6666:7777
`

	if err := os.WriteFile(path, []byte(defaultConfig), 0644); err != nil {
		return fmt.Errorf("create whitelist config failed: %w", err)
	}

	log.Printf("created empty whitelist config: %s", path)
	return nil
}

func loadWhitelist(path string) (map[string]struct{}, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open whitelist config failed: %w", err)
	}
	defer f.Close()

	allowed := make(map[string]struct{})
	sc := bufio.NewScanner(f)
	lineNo := 0
	for sc.Scan() {
		lineNo++
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		ip := net.ParseIP(line)
		if ip == nil || ip.To16() == nil || ip.To4() != nil {
			return nil, fmt.Errorf("invalid IPv6 in whitelist at %s:%d: %q", path, lineNo, line)
		}
		allowed[ip.To16().String()] = struct{}{}
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("read whitelist config failed: %w", err)
	}

	return allowed, nil
}

func main() {
	var listenAddr string
	var tunName string
	var tunCIDR string
	var tunMTU int

	flag.StringVar(&listenAddr, "listen", "", "UDP listen address, e.g. [200:xxxx:....]:40001")
	flag.StringVar(&tunName, "tun-name", "yggexit0", "TUN interface name")
	flag.StringVar(&tunCIDR, "tun-cidr", "10.66.0.1/24", "CIDR address for TUN")
	flag.IntVar(&tunMTU, "tun-mtu", 1500, "MTU for TUN interface")
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
	whitelist, err := loadWhitelist(whitelistConfigPath)
	if err != nil {
		log.Fatalf("whitelist config load failed: %v", err)
	}
	log.Printf("whitelist loaded: %d client(s)", len(whitelist))

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

			addrIP := addr.IP.To16()
			if addrIP == nil || addr.IP.To4() != nil {
				log.Printf("ignoring non-IPv6 client %s", addr.String())
				continue
			}
			if _, ok := whitelist[addrIP.String()]; !ok {
				log.Printf("ignoring non-whitelisted client %s", addr.String())
				continue
			}

			srcIP, _, ok := parsePacketIPs(buf[:n])
			if !ok {
				log.Printf("ignoring malformed IP packet from %s", addr.String())
				continue
			}

			peerByInnerIP.Set(srcIP, addr)

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
