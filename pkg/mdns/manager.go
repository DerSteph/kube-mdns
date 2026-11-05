package mdns

import (
	"context"
	"fmt"
	"log"
	"net"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/miekg/dns"
	"golang.org/x/net/ipv4"
	"golang.org/x/net/ipv6"
	"golang.org/x/sys/unix"
)

const (
	mdnsIPv4Addr = "224.0.0.251:5353"
	mdnsIPv6Addr = "[ff02::fb]:5353"
	defaultTTL   = 120
)

// Record represents a single service and host record to publish.
type Record struct {
	Hostname    string
	IPs         []string
	Port        int
	ServiceType string
}

type serviceEntry struct {
	instanceName string   // e.g. "immich"
	hostName     string   // e.g. "immich.local."
	serviceType  string   // e.g. "_http._tcp.local."
	instanceFull string   // e.g. "immich._http._tcp.local."
	port         int      // e.g. 80
	ips          []net.IP // parsed IPs
}

// Manager manages mDNS records and responds to queries over multicast.
type Manager struct {
	mu        sync.RWMutex
	defaultST string
	ifaces    []net.Interface

	// Key (e.g. namespace/name) -> list of entries
	byKey map[string][]*serviceEntry

	// Indexed lookup tables
	byHost     map[string][]*serviceEntry // "immich.local." -> entries
	byService  map[string][]*serviceEntry // "_http._tcp.local." -> entries
	byInstance map[string]*serviceEntry   // "immich._http._tcp.local." -> entry

	pconn4 *ipv4.PacketConn
	pconn6 *ipv6.PacketConn

	cancel context.CancelFunc
	wg     sync.WaitGroup
}

// NewManager creates and starts a single mDNS manager bound to the given interface.
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
		// Discover all multicast-capable interfaces
		allIfs, err := net.Interfaces()
		if err == nil {
			for _, ifi := range allIfs {
				if ifi.Flags&net.FlagUp != 0 && ifi.Flags&net.FlagMulticast != 0 {
					ifaces = append(ifaces, ifi)
				}
			}
		}
		log.Printf("mDNS Manager will bind to %d multicast interface(s)", len(ifaces))
	}

	st := normalizeServiceType(defaultServiceType)
	if st == "" {
		st = "_http._tcp.local."
	}

	ctx, cancel := context.WithCancel(context.Background())

	m := &Manager{
		defaultST:  st,
		ifaces:     ifaces,
		byKey:      make(map[string][]*serviceEntry),
		byHost:     make(map[string][]*serviceEntry),
		byService:  make(map[string][]*serviceEntry),
		byInstance: make(map[string]*serviceEntry),
		cancel:     cancel,
	}

	if err := m.startListeners(ctx); err != nil {
		cancel()
		return nil, fmt.Errorf("failed to start mDNS listeners: %w", err)
	}

	return m, nil
}

func (m *Manager) startListeners(ctx context.Context) error {
	lc := net.ListenConfig{
		Control: func(network, address string, c syscall.RawConn) error {
			var opErr error
			err := c.Control(func(fd uintptr) {
				opErr = unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_REUSEADDR, 1)
				if opErr != nil {
					return
				}
				opErr = unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_REUSEPORT, 1)
			})
			if err != nil {
				return err
			}
			return opErr
		},
	}

	// 1. IPv4 Listener
	c4, err := lc.ListenPacket(ctx, "udp4", "0.0.0.0:5353")
	if err != nil {
		log.Printf("Warning: failed to bind IPv4 mDNS socket (0.0.0.0:5353): %v", err)
	} else {
		pconn4 := ipv4.NewPacketConn(c4)
		_ = pconn4.SetControlMessage(ipv4.FlagInterface, true)
		_ = pconn4.SetMulticastLoopback(true)
		if len(m.ifaces) == 1 {
			_ = pconn4.SetMulticastInterface(&m.ifaces[0])
		}

		var joined int
		for _, ifi := range m.ifaces {
			if err := pconn4.JoinGroup(&ifi, &net.UDPAddr{IP: net.IPv4(224, 0, 0, 251)}); err == nil {
				joined++
			} else {
				log.Printf("Warning: IPv4 failed to join 224.0.0.251 on %s: %v", ifi.Name, err)
			}
		}
		if joined > 0 {
			m.pconn4 = pconn4
			m.wg.Add(1)
			go m.readLoopIPv4(pconn4)
		} else {
			_ = c4.Close()
		}
	}

	// 2. IPv6 Listener (best-effort)
	c6, err := lc.ListenPacket(ctx, "udp6", "[::]:5353")
	if err != nil {
		log.Printf("Note: IPv6 mDNS socket not available: %v", err)
	} else {
		pconn6 := ipv6.NewPacketConn(c6)
		_ = pconn6.SetControlMessage(ipv6.FlagInterface, true)

		var joined int
		for _, ifi := range m.ifaces {
			if err := pconn6.JoinGroup(&ifi, &net.UDPAddr{IP: net.ParseIP("ff02::fb")}); err == nil {
				joined++
			}
		}
		if joined > 0 {
			m.pconn6 = pconn6
			m.wg.Add(1)
			go m.readLoopIPv6(pconn6)
		} else {
			_ = c6.Close()
		}
	}

	if m.pconn4 == nil && m.pconn6 == nil {
		return fmt.Errorf("unable to bind any multicast UDP sockets on port 5353")
	}

	return nil
}

// Publish registers mDNS records for a given key and sends unsolicited announcements.
func (m *Manager) Publish(key string, records []Record) error {
	m.mu.Lock()

	// Unpublish old records for this key first if present
	if oldEntries, exists := m.byKey[key]; exists {
		m.removeEntriesLocked(key, oldEntries)
		go m.sendGoodbye(oldEntries)
	}

	var newEntries []*serviceEntry
	for _, rec := range records {
		host := canonicalHostName(rec.Hostname)
		instance := strings.TrimSuffix(strings.TrimSuffix(host, "."), ".local")
		st := rec.ServiceType
		if st == "" {
			st = m.defaultST
		}
		st = normalizeServiceType(st)
		instanceFull := fmt.Sprintf("%s.%s", instance, st)

		var ips []net.IP
		for _, ipStr := range rec.IPs {
			if ip := net.ParseIP(ipStr); ip != nil {
				ips = append(ips, ip)
			}
		}

		entry := &serviceEntry{
			instanceName: instance,
			hostName:     host,
			serviceType:  st,
			instanceFull: instanceFull,
			port:         rec.Port,
			ips:          ips,
		}
		newEntries = append(newEntries, entry)
		log.Printf("[%s] Registering mDNS record: instance=%q host=%q port=%d ips=%v service=%q",
			key, instance, host, rec.Port, rec.IPs, st)
	}

	m.addEntriesLocked(key, newEntries)
	m.mu.Unlock()

	// Send unsolicited announcements (gratuitous mDNS)
	go m.sendAnnouncements(newEntries)

	return nil
}

// Unpublish deregisters all records associated with key and sends goodbye packets.
func (m *Manager) Unpublish(key string) {
	m.mu.Lock()
	entries, exists := m.byKey[key]
	if !exists {
		m.mu.Unlock()
		return
	}
	m.removeEntriesLocked(key, entries)
	m.mu.Unlock()

	go m.sendGoodbye(entries)
}

// Close gracefully stops listeners and announces goodbye for all records.
func (m *Manager) Close() error {
	return m.Shutdown()
}

// Shutdown gracefully stops listeners and announces goodbye for all records.
func (m *Manager) Shutdown() error {
	m.cancel()

	m.mu.Lock()
	var allEntries []*serviceEntry
	for _, entries := range m.byKey {
		allEntries = append(allEntries, entries...)
	}
	m.byKey = make(map[string][]*serviceEntry)
	m.byHost = make(map[string][]*serviceEntry)
	m.byService = make(map[string][]*serviceEntry)
	m.byInstance = make(map[string]*serviceEntry)
	m.mu.Unlock()

	m.sendGoodbye(allEntries)

	if m.pconn4 != nil {
		_ = m.pconn4.Close()
	}
	if m.pconn6 != nil {
		_ = m.pconn6.Close()
	}

	m.wg.Wait()
	return nil
}

func (m *Manager) addEntriesLocked(key string, entries []*serviceEntry) {
	m.byKey[key] = entries
	for _, e := range entries {
		m.byHost[e.hostName] = append(m.byHost[e.hostName], e)
		m.byService[e.serviceType] = append(m.byService[e.serviceType], e)
		m.byInstance[e.instanceFull] = e
	}
}

func (m *Manager) removeEntriesLocked(key string, entries []*serviceEntry) {
	delete(m.byKey, key)
	for _, e := range entries {
		delete(m.byInstance, e.instanceFull)

		// Remove from byHost
		hostList := m.byHost[e.hostName]
		var newHostList []*serviceEntry
		for _, item := range hostList {
			if item != e {
				newHostList = append(newHostList, item)
			}
		}
		if len(newHostList) > 0 {
			m.byHost[e.hostName] = newHostList
		} else {
			delete(m.byHost, e.hostName)
		}

		// Remove from byService
		svcList := m.byService[e.serviceType]
		var newSvcList []*serviceEntry
		for _, item := range svcList {
			if item != e {
				newSvcList = append(newSvcList, item)
			}
		}
		if len(newSvcList) > 0 {
			m.byService[e.serviceType] = newSvcList
		} else {
			delete(m.byService, e.serviceType)
		}
	}
}

func (m *Manager) readLoopIPv4(pconn *ipv4.PacketConn) {
	defer m.wg.Done()
	buf := make([]byte, 65535)
	for {
		n, cm, from, err := pconn.ReadFrom(buf)
		if err != nil {
			return
		}
		var msg dns.Msg
		if err := msg.Unpack(buf[:n]); err != nil || msg.Response {
			continue
		}
		ifIndex := 0
		if cm != nil {
			ifIndex = cm.IfIndex
		}
		m.handleQuery(&msg, from, ifIndex, false)
	}
}

func (m *Manager) readLoopIPv6(pconn *ipv6.PacketConn) {
	defer m.wg.Done()
	buf := make([]byte, 65535)
	for {
		n, cm, from, err := pconn.ReadFrom(buf)
		if err != nil {
			return
		}
		var msg dns.Msg
		if err := msg.Unpack(buf[:n]); err != nil || msg.Response {
			continue
		}
		ifIndex := 0
		if cm != nil {
			ifIndex = cm.IfIndex
		}
		m.handleQuery(&msg, from, ifIndex, true)
	}
}

func (m *Manager) handleQuery(query *dns.Msg, from net.Addr, ifIndex int, isIPv6 bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	var answers []dns.RR
	var extras []dns.RR
	unicastRequested := false

	for _, q := range query.Question {
		qName := strings.ToLower(q.Name)
		if !strings.HasSuffix(qName, ".") {
			qName += "."
		}

		// Check QU (unicast-response) bit in question class
		if q.Qclass&0x8000 != 0 {
			unicastRequested = true
		}

		// 1. Host resolution: A / AAAA
		if q.Qtype == dns.TypeA || q.Qtype == dns.TypeAAAA || q.Qtype == dns.TypeANY {
			if entries, ok := m.byHost[qName]; ok {
				for _, e := range entries {
					for _, ip := range e.ips {
						if ip4 := ip.To4(); ip4 != nil {
							if q.Qtype == dns.TypeA || q.Qtype == dns.TypeANY {
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
						} else {
							if q.Qtype == dns.TypeAAAA || q.Qtype == dns.TypeANY {
								answers = append(answers, &dns.AAAA{
									Hdr: dns.RR_Header{
										Name:   e.hostName,
										Rrtype: dns.TypeAAAA,
										Class:  dns.ClassINET | 0x8000,
										Ttl:    defaultTTL,
									},
									AAAA: ip,
								})
							}
						}
					}
				}
			}
		}

		// 2. Service Browsing: PTR
		if q.Qtype == dns.TypePTR || q.Qtype == dns.TypeANY {
			if qName == "_services._dns-sd._udp.local." {
				seen := make(map[string]bool)
				for _, e := range m.byInstance {
					if !seen[e.serviceType] {
						seen[e.serviceType] = true
						answers = append(answers, &dns.PTR{
							Hdr: dns.RR_Header{
								Name:   qName,
								Rrtype: dns.TypePTR,
								Class:  dns.ClassINET,
								Ttl:    defaultTTL,
							},
							Ptr: e.serviceType,
						})
					}
				}
			} else if entries, ok := m.byService[qName]; ok {
				for _, e := range entries {
					answers = append(answers, &dns.PTR{
						Hdr: dns.RR_Header{
							Name:   e.serviceType,
							Rrtype: dns.TypePTR,
							Class:  dns.ClassINET,
							Ttl:    defaultTTL,
						},
						Ptr: e.instanceFull,
					})
					// Add SRV and A records to Extras
					extras = append(extras, &dns.SRV{
						Hdr: dns.RR_Header{
							Name:   e.instanceFull,
							Rrtype: dns.TypeSRV,
							Class:  dns.ClassINET | 0x8000,
							Ttl:    defaultTTL,
						},
						Target: e.hostName,
						Port:   uint16(e.port),
					})
					for _, ip := range e.ips {
						if ip4 := ip.To4(); ip4 != nil {
							extras = append(extras, &dns.A{
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

		// 3. Service Instance lookup: SRV / TXT
		if q.Qtype == dns.TypeSRV || q.Qtype == dns.TypeTXT || q.Qtype == dns.TypeANY {
			if e, ok := m.byInstance[qName]; ok {
				if q.Qtype == dns.TypeSRV || q.Qtype == dns.TypeANY {
					answers = append(answers, &dns.SRV{
						Hdr: dns.RR_Header{
							Name:   e.instanceFull,
							Rrtype: dns.TypeSRV,
							Class:  dns.ClassINET | 0x8000,
							Ttl:    defaultTTL,
						},
						Target: e.hostName,
						Port:   uint16(e.port),
					})
					for _, ip := range e.ips {
						if ip4 := ip.To4(); ip4 != nil {
							extras = append(extras, &dns.A{
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
				if q.Qtype == dns.TypeTXT || q.Qtype == dns.TypeANY {
					answers = append(answers, &dns.TXT{
						Hdr: dns.RR_Header{
							Name:   e.instanceFull,
							Rrtype: dns.TypeTXT,
							Class:  dns.ClassINET | 0x8000,
							Ttl:    defaultTTL,
						},
						Txt: []string{""},
					})
				}
			}
		}
	}

	if len(answers) == 0 {
		return
	}

	log.Printf("Answering mDNS query from %v for %v with %d record(s)", from, query.Question[0].Name, len(answers))

	resp := dns.Msg{}
	resp.SetReply(query)
	resp.Response = true
	resp.Authoritative = true
	resp.RecursionAvailable = false
	resp.Question = nil // RFC 6762 Section 6: Responses MUST NOT contain questions
	resp.Answer = answers
	resp.Extra = extras

	data, err := resp.Pack()
	if err != nil {
		return
	}

	if unicastRequested {
		m.sendPacketUnicast(data, from, ifIndex, isIPv6)
	} else {
		m.sendPacketMulticast(data, ifIndex, isIPv6)
	}
}

func (m *Manager) sendPacketMulticast(data []byte, ifIndex int, isIPv6 bool) {
	if !isIPv6 && m.pconn4 != nil {
		dst := &net.UDPAddr{IP: net.IPv4(224, 0, 0, 251), Port: 5353}
		var wcm *ipv4.ControlMessage
		if ifIndex > 0 {
			wcm = &ipv4.ControlMessage{IfIndex: ifIndex}
		}
		if _, err := m.pconn4.WriteTo(data, wcm, dst); err != nil {
			log.Printf("mDNS IPv4 multicast send error: %v", err)
		}
	}
	if isIPv6 && m.pconn6 != nil {
		dst := &net.UDPAddr{IP: net.ParseIP("ff02::fb"), Port: 5353}
		var wcm *ipv6.ControlMessage
		if ifIndex > 0 {
			wcm = &ipv6.ControlMessage{IfIndex: ifIndex}
		}
		if _, err := m.pconn6.WriteTo(data, wcm, dst); err != nil {
			log.Printf("mDNS IPv6 multicast send error: %v", err)
		}
	}
}

func (m *Manager) sendPacketUnicast(data []byte, to net.Addr, ifIndex int, isIPv6 bool) {
	if !isIPv6 && m.pconn4 != nil {
		if _, err := m.pconn4.WriteTo(data, nil, to); err != nil {
			log.Printf("mDNS IPv4 unicast send to %v error: %v", to, err)
		}
	}
	if isIPv6 && m.pconn6 != nil {
		var wcm *ipv6.ControlMessage
		if ifIndex > 0 {
			wcm = &ipv6.ControlMessage{IfIndex: ifIndex}
		}
		if _, err := m.pconn6.WriteTo(data, wcm, to); err != nil {
			log.Printf("mDNS IPv6 unicast send to %v error: %v", to, err)
		}
	}
}

func (m *Manager) sendAnnouncements(entries []*serviceEntry) {
	if len(entries) == 0 {
		return
	}
	msg := buildAnnouncementMessage(entries, defaultTTL)
	data, err := msg.Pack()
	if err != nil {
		log.Printf("Error packing announcement message: %v", err)
		return
	}

	for _, e := range entries {
		log.Printf("Broadcasting mDNS announcement: host=%q ips=%v service=%q port=%d", e.hostName, e.ips, e.serviceType, e.port)
	}

	// Send announcement twice with 250ms spacing (RFC 6762 Section 8.3)
	for i := 0; i < 2; i++ {
		m.broadcastToAll(data)
		time.Sleep(250 * time.Millisecond)
	}
}

func (m *Manager) sendGoodbye(entries []*serviceEntry) {
	if len(entries) == 0 {
		return
	}
	// RFC 6762 Section 10.1: Goodbye packet has TTL=0
	msg := buildAnnouncementMessage(entries, 0)
	data, err := msg.Pack()
	if err != nil {
		return
	}
	m.broadcastToAll(data)
}

func (m *Manager) broadcastToAll(data []byte) {
	if m.pconn4 != nil {
		dst := &net.UDPAddr{IP: net.IPv4(224, 0, 0, 251), Port: 5353}
		for _, ifi := range m.ifaces {
			_ = m.pconn4.SetMulticastInterface(&ifi)
			wcm := &ipv4.ControlMessage{IfIndex: ifi.Index}
			if _, err := m.pconn4.WriteTo(data, wcm, dst); err != nil {
				if _, err2 := m.pconn4.WriteTo(data, nil, dst); err2 != nil {
					log.Printf("Warning: IPv4 broadcast error on %s: %v", ifi.Name, err2)
				}
			}
		}
	}
	if m.pconn6 != nil {
		dst := &net.UDPAddr{IP: net.ParseIP("ff02::fb"), Port: 5353}
		for _, ifi := range m.ifaces {
			_ = m.pconn6.SetMulticastInterface(&ifi)
			wcm := &ipv6.ControlMessage{IfIndex: ifi.Index}
			if _, err := m.pconn6.WriteTo(data, wcm, dst); err != nil {
				_, _ = m.pconn6.WriteTo(data, nil, dst)
			}
		}
	}
}

func buildAnnouncementMessage(entries []*serviceEntry, ttl uint32) *dns.Msg {
	msg := &dns.Msg{}
	msg.Response = true
	msg.Authoritative = true

	for _, e := range entries {
		// A / AAAA
		for _, ip := range e.ips {
			if ip4 := ip.To4(); ip4 != nil {
				msg.Answer = append(msg.Answer, &dns.A{
					Hdr: dns.RR_Header{
						Name:   e.hostName,
						Rrtype: dns.TypeA,
						Class:  dns.ClassINET | 0x8000,
						Ttl:    ttl,
					},
					A: ip4,
				})
			} else {
				msg.Answer = append(msg.Answer, &dns.AAAA{
					Hdr: dns.RR_Header{
						Name:   e.hostName,
						Rrtype: dns.TypeAAAA,
						Class:  dns.ClassINET | 0x8000,
						Ttl:    ttl,
					},
					AAAA: ip,
				})
			}
		}
		// SRV
		msg.Answer = append(msg.Answer, &dns.SRV{
			Hdr: dns.RR_Header{
				Name:   e.instanceFull,
				Rrtype: dns.TypeSRV,
				Class:  dns.ClassINET | 0x8000,
				Ttl:    ttl,
			},
			Target: e.hostName,
			Port:   uint16(e.port),
		})
		// PTR
		msg.Answer = append(msg.Answer, &dns.PTR{
			Hdr: dns.RR_Header{
				Name:   e.serviceType,
				Rrtype: dns.TypePTR,
				Class:  dns.ClassINET,
				Ttl:    ttl,
			},
			Ptr: e.instanceFull,
		})
	}
	return msg
}

func canonicalHostName(name string) string {
	h := strings.ToLower(strings.TrimSpace(name))
	h = strings.TrimSuffix(h, ".")
	if !strings.HasSuffix(h, ".local") {
		h += ".local"
	}
	return h + "."
}

func normalizeServiceType(st string) string {
	s := strings.ToLower(strings.TrimSpace(st))
	s = strings.TrimSuffix(s, ".")
	s = strings.TrimSuffix(s, ".local")
	if s == "" {
		return "_http._tcp.local."
	}
	return s + ".local."
}
