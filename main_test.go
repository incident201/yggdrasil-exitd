package main

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeTempConfig(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "ygg-exitd.conf")
	if err := os.WriteFile(path, []byte(body), 0644); err != nil {
		t.Fatalf("write temp config: %v", err)
	}
	return path
}

func TestLoadWhitelist_EmptyConfig(t *testing.T) {
	path := writeTempConfig(t, "# empty\n\n")
	got, err := loadWhitelist(path, "10.66.0.1/24")
	if err != nil {
		t.Fatalf("loadWhitelist returned error: %v", err)
	}
	if len(got.byYgg) != 0 {
		t.Fatalf("expected 0 clients, got %d", len(got.byYgg))
	}
}

func TestLoadWhitelist_ValidEntry(t *testing.T) {
	path := writeTempConfig(t, "200:aaaa:bbbb:cccc:dddd:eeee:ffff:0001 10.66.0.10\n")
	got, err := loadWhitelist(path, "10.66.0.1/24")
	if err != nil {
		t.Fatalf("loadWhitelist returned error: %v", err)
	}
	if len(got.byYgg) != 1 {
		t.Fatalf("expected 1 client, got %d", len(got.byYgg))
	}
}

func TestLoadWhitelist_RejectsLegacyOneColumnFormat(t *testing.T) {
	path := writeTempConfig(t, "200:aaaa:bbbb:cccc:dddd:eeee:ffff:0001\n")
	_, err := loadWhitelist(path, "10.66.0.1/24")
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !strings.Contains(err.Error(), "expected '<client-yggdrasil-ipv6> <client-inner-ipv4>'") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestLoadWhitelist_RejectsDuplicateInnerIPv4(t *testing.T) {
	path := writeTempConfig(t, ""+
		"200:aaaa:bbbb:cccc:dddd:eeee:ffff:0001 10.66.0.10\n"+
		"200:aaaa:bbbb:cccc:dddd:eeee:ffff:0002 10.66.0.10\n")
	_, err := loadWhitelist(path, "10.66.0.1/24")
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !strings.Contains(err.Error(), "duplicate client inner IPv4") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestLoadWhitelist_RejectsDuplicateYggIPv6(t *testing.T) {
	path := writeTempConfig(t, ""+
		"200:aaaa:bbbb:cccc:dddd:eeee:ffff:0001 10.66.0.10\n"+
		"200:aaaa:bbbb:cccc:dddd:eeee:ffff:0001 10.66.0.11\n")
	_, err := loadWhitelist(path, "10.66.0.1/24")
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !strings.Contains(err.Error(), "duplicate client Yggdrasil IPv6") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestLoadWhitelist_RejectsInnerOutsideTunCIDR(t *testing.T) {
	path := writeTempConfig(t, "200:aaaa:bbbb:cccc:dddd:eeee:ffff:0001 10.99.0.10\n")
	_, err := loadWhitelist(path, "10.66.0.1/24")
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !strings.Contains(err.Error(), "outside --tun-cidr") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestLoadWhitelist_RejectsInnerEqualTunIP(t *testing.T) {
	path := writeTempConfig(t, "200:aaaa:bbbb:cccc:dddd:eeee:ffff:0001 10.66.0.1\n")
	_, err := loadWhitelist(path, "10.66.0.1/24")
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !strings.Contains(err.Error(), "must not be equal to TUN interface address") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestPacketAllowedForClient(t *testing.T) {
	cfg := "" +
		"200:aaaa:bbbb:cccc:dddd:eeee:ffff:0001 10.66.0.10\n" +
		"200:aaaa:bbbb:cccc:dddd:eeee:ffff:0002 10.66.0.11\n"
	path := writeTempConfig(t, cfg)
	bindings, err := loadWhitelist(path, "10.66.0.1/24")
	if err != nil {
		t.Fatalf("loadWhitelist returned error: %v", err)
	}

	okPkt := []byte{
		0x45, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x00, 0x40, 0x11, 0x00, 0x00,
		10, 66, 0, 10,
		1, 1, 1, 1,
	}

	inner, ok := packetAllowedForClient(parseIPOrFail(t, "200:aaaa:bbbb:cccc:dddd:eeee:ffff:0001"), okPkt, bindings)
	if !ok {
		t.Fatal("expected packet to be accepted")
	}
	if inner.String() != "10.66.0.10" {
		t.Fatalf("unexpected assigned inner ip: %s", inner.String())
	}
}

func TestPacketRejectedOnSourceMismatch(t *testing.T) {
	cfg := "200:aaaa:bbbb:cccc:dddd:eeee:ffff:0001 10.66.0.10\n"
	path := writeTempConfig(t, cfg)
	bindings, err := loadWhitelist(path, "10.66.0.1/24")
	if err != nil {
		t.Fatalf("loadWhitelist returned error: %v", err)
	}

	badPkt := []byte{
		0x45, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x00, 0x40, 0x11, 0x00, 0x00,
		10, 66, 0, 11,
		1, 1, 1, 1,
	}

	if _, ok := packetAllowedForClient(parseIPOrFail(t, "200:aaaa:bbbb:cccc:dddd:eeee:ffff:0001"), badPkt, bindings); ok {
		t.Fatal("expected packet to be rejected")
	}
}

func TestPacketRejectedFromUnknownYggIPv6(t *testing.T) {
	cfg := "200:aaaa:bbbb:cccc:dddd:eeee:ffff:0001 10.66.0.10\n"
	path := writeTempConfig(t, cfg)
	bindings, err := loadWhitelist(path, "10.66.0.1/24")
	if err != nil {
		t.Fatalf("loadWhitelist returned error: %v", err)
	}

	okPkt := []byte{
		0x45, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x00, 0x40, 0x11, 0x00, 0x00,
		10, 66, 0, 10,
		1, 1, 1, 1,
	}

	if _, ok := packetAllowedForClient(parseIPOrFail(t, "200:aaaa:bbbb:cccc:dddd:eeee:ffff:0002"), okPkt, bindings); ok {
		t.Fatal("expected packet to be rejected")
	}
}

func parseIPOrFail(t *testing.T, raw string) net.IP {
	t.Helper()
	ip := net.ParseIP(raw)
	if ip == nil {
		t.Fatalf("invalid test ip: %s", raw)
	}
	return ip
}
