package main

import (
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

type peerState struct {
	mu   sync.RWMutex
	addr *net.UDPAddr
}

func (p *peerState) Set(addr *net.UDPAddr) {
	if addr == nil {
		return
	}
	cp := &net.UDPAddr{
		IP:   append(net.IP(nil), addr.IP...),
		Port: addr.Port,
		Zone: addr.Zone,
	}
	p.mu.Lock()
	p.addr = cp
	p.mu.Unlock()
}

func (p *peerState) Get() *net.UDPAddr {
	p.mu.RLock()
	defer p.mu.RUnlock()
	if p.addr == nil {
		return nil
	}
	return &net.UDPAddr{
		IP:   append(net.IP(nil), p.addr.IP...),
		Port: p.addr.Port,
		Zone: p.addr.Zone,
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

func main() {
	var listenAddr string
	var tunName string
	var tunCIDR string
	var tunMTU int
	var allowedClientIP string

	flag.StringVar(&listenAddr, "listen", "", "UDP listen address, e.g. [200:xxxx:....]:40001")
	flag.StringVar(&tunName, "tun-name", "yggexit0", "TUN interface name")
	flag.StringVar(&tunCIDR, "tun-cidr", "10.66.0.1/24", "CIDR address for TUN")
	flag.IntVar(&tunMTU, "tun-mtu", 1500, "MTU for TUN interface")
	flag.StringVar(&allowedClientIP, "client-ip", "", "optional allowed client Yggdrasil IPv6")
	flag.Parse()

	if listenAddr == "" {
		log.Fatal("missing --listen")
	}

	var allowedIP net.IP
	if allowedClientIP != "" {
		allowedIP = net.ParseIP(allowedClientIP)
		if allowedIP == nil || allowedIP.To16() == nil || allowedIP.To4() != nil {
			log.Fatalf("invalid --client-ip: %s", allowedClientIP)
		}
		allowedIP = allowedIP.To16()
	}

	if os.Geteuid() != 0 {
		log.Fatal("run as root")
	}

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

	var peers peerState
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

			if allowedIP != nil && !addr.IP.To16().Equal(allowedIP) {
				log.Printf("ignoring packet from unexpected client %s", addr.String())
				continue
			}

			peers.Set(addr)

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

			peer := peers.Get()
			if peer == nil {
				// Пока клиент ещё не прислал ни одного пакета,
				// мы не знаем, куда отправлять ответы.
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