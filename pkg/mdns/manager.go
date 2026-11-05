package mdns

import (
	"fmt"
	"log"
	"net"
	"strings"
	"sync"

	"github.com/grandcat/zeroconf"
)

type Record struct {
	Hostname    string
	IPs         []string
	Port        int
	ServiceType string
}

type Manager struct {
	mu            sync.Mutex
	ifaces        []net.Interface
	defaultST     string
	registrations map[string][]*zeroconf.Server
}

func NewManager(ifaceName, defaultServiceType string) (*Manager, error) {
	var ifaces []net.Interface
	if ifaceName != "" {
		ifi, err := net.InterfaceByName(ifaceName)
		if err != nil {
			return nil, fmt.Errorf("failed to find network interface %q: %w", ifaceName, err)
		}
		ifaces = []net.Interface{*ifi}
		log.Printf("mDNS Manager bound to interface: %s (MAC: %s)", ifi.Name, ifi.HardwareAddr)
	} else {
		log.Printf("mDNS Manager will bind to all available multicast interfaces")
	}

	st := defaultServiceType
	if st == "" {
		st = "_http._tcp"
	}
	// Normalize service type: strip trailing dot or .local.
	st = strings.TrimSuffix(st, ".")
	st = strings.TrimSuffix(st, ".local")

	return &Manager{
		ifaces:        ifaces,
		defaultST:     st,
		registrations: make(map[string][]*zeroconf.Server),
	}, nil
}

// Publish registers mDNS records for a given key (e.g., "namespace/name" or "manual/host").
func (m *Manager) Publish(key string, records []Record) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	// Deregister any existing records for this key
	m.unpublishLocked(key)

	var servers []*zeroconf.Server
	for _, rec := range records {
		st := rec.ServiceType
		if st == "" {
			st = m.defaultST
		}
		st = strings.TrimSuffix(st, ".")
		st = strings.TrimSuffix(st, ".local")

		// Extract clean host name
		host := strings.TrimSuffix(rec.Hostname, ".")
		instance := strings.TrimSuffix(host, ".local")

		log.Printf("[%s] Registering mDNS proxy: instance=%q host=%q port=%d ips=%v service=%q",
			key, instance, host, rec.Port, rec.IPs, st)

		srv, err := zeroconf.RegisterProxy(
			instance,
			st,
			"local.",
			rec.Port,
			host,
			rec.IPs,
			nil, // TXT records
			m.ifaces,
		)
		if err != nil {
			log.Printf("[%s] Error registering mDNS proxy for %s: %v", key, host, err)
			continue
		}
		servers = append(servers, srv)
	}

	if len(servers) > 0 {
		m.registrations[key] = servers
	}
	return nil
}

// Unpublish removes mDNS records for a key.
func (m *Manager) Unpublish(key string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.unpublishLocked(key)
}

func (m *Manager) unpublishLocked(key string) {
	if srvs, exists := m.registrations[key]; exists {
		log.Printf("[%s] Unregistering %d mDNS record(s)", key, len(srvs))
		for _, s := range srvs {
			s.Shutdown()
		}
		delete(m.registrations, key)
	}
}

// Shutdown stops all active mDNS announcements.
func (m *Manager) Shutdown() {
	m.mu.Lock()
	defer m.mu.Unlock()

	log.Printf("Shutting down all mDNS announcements...")
	for key, srvs := range m.registrations {
		for _, s := range srvs {
			s.Shutdown()
		}
		delete(m.registrations, key)
	}
}
