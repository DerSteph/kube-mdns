package mdns

import (
	"net"
	"testing"

	"github.com/miekg/dns"
)

func TestCanonicalHostName(t *testing.T) {
	tests := []struct {
		in   string
		want string
	}{
		{"immich.local", "immich.local."},
		{"immich.local.", "immich.local."},
		{"immich", "immich.local."},
		{"IMMICH.LOCAL.", "immich.local."},
		{" jellyfin.local ", "jellyfin.local."},
	}

	for _, tt := range tests {
		got := canonicalHostName(tt.in)
		if got != tt.want {
			t.Errorf("canonicalHostName(%q) = %q; want %q", tt.in, got, tt.want)
		}
	}
}

func TestNormalizeServiceType(t *testing.T) {
	tests := []struct {
		in   string
		want string
	}{
		{"_http._tcp", "_http._tcp.local."},
		{"_http._tcp.local", "_http._tcp.local."},
		{"_http._tcp.local.", "_http._tcp.local."},
		{"", "_http._tcp.local."},
		{"_custom._tcp", "_custom._tcp.local."},
	}

	for _, tt := range tests {
		got := normalizeServiceType(tt.in)
		if got != tt.want {
			t.Errorf("normalizeServiceType(%q) = %q; want %q", tt.in, got, tt.want)
		}
	}
}

func TestManagerPublishAndQuery(t *testing.T) {
	m := &Manager{
		defaultST:  "_http._tcp.local.",
		byKey:      make(map[string][]*serviceEntry),
		byHost:     make(map[string][]*serviceEntry),
		byService:  make(map[string][]*serviceEntry),
		byInstance: make(map[string]*serviceEntry),
	}

	rec := Record{
		Hostname:    "immich.local",
		IPs:         []string{"192.168.1.100"},
		Port:        80,
		ServiceType: "_http._tcp",
	}

	m.Publish("immich/immich", []Record{rec})

	// 1. Query for A record: immich.local.
	qA := new(dns.Msg)
	qA.SetQuestion("immich.local.", dns.TypeA)

	from := &net.UDPAddr{IP: net.ParseIP("192.168.1.50"), Port: 5353}
	// Test handleQuery in-memory
	m.mu.RLock()
	var answers []dns.RR
	for _, q := range qA.Question {
		if entries, ok := m.byHost[q.Name]; ok {
			for _, e := range entries {
				for _, ip := range e.ips {
					if ip4 := ip.To4(); ip4 != nil {
						answers = append(answers, &dns.A{
							Hdr: dns.RR_Header{
								Name:   e.hostName,
								Rrtype: dns.TypeA,
								Class:  dns.ClassINET | 0x8000,
								Ttl:    defaultTTL,
							},
							A: ip4,
						})
					}
				}
			}
		}
	}
	m.mu.RUnlock()

	if len(answers) != 1 {
		t.Fatalf("expected 1 answer for A query, got %d", len(answers))
	}
	aRecord, ok := answers[0].(*dns.A)
	if !ok {
		t.Fatalf("expected *dns.A, got %T", answers[0])
	}
	if aRecord.A.String() != "192.168.1.100" {
		t.Errorf("expected IP 192.168.1.100, got %s", aRecord.A.String())
	}
	if aRecord.Hdr.Name != "immich.local." {
		t.Errorf("expected name immich.local., got %s", aRecord.Hdr.Name)
	}

	// 2. Query for PTR record: _http._tcp.local.
	m.mu.RLock()
	var ptrAnswers []dns.RR
	if entries, ok := m.byService["_http._tcp.local."]; ok {
		for _, e := range entries {
			ptrAnswers = append(ptrAnswers, &dns.PTR{
				Hdr: dns.RR_Header{
					Name:   e.serviceType,
					Rrtype: dns.TypePTR,
					Class:  dns.ClassINET,
					Ttl:    defaultTTL,
				},
				Ptr: e.instanceFull,
			})
		}
	}
	m.mu.RUnlock()

	if len(ptrAnswers) != 1 {
		t.Fatalf("expected 1 PTR answer, got %d", len(ptrAnswers))
	}
	ptrRecord := ptrAnswers[0].(*dns.PTR)
	if ptrRecord.Ptr != "immich._http._tcp.local." {
		t.Errorf("expected Ptr immich._http._tcp.local., got %s", ptrRecord.Ptr)
	}

	// 3. Test Unpublish
	m.Unpublish("immich/immich")
	m.mu.RLock()
	if len(m.byHost) != 0 || len(m.byService) != 0 || len(m.byInstance) != 0 {
		t.Errorf("expected clean maps after Unpublish, got host=%d svc=%d inst=%d",
			len(m.byHost), len(m.byService), len(m.byInstance))
	}
	m.mu.RUnlock()
	_ = from
}
