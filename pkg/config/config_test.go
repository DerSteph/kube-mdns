package config

import (
	"os"
	"testing"
)

func TestLoadManualHosts(t *testing.T) {
	data := `[
		{
			"hostname": "homeassistant.local",
			"ip": "192.168.1.101",
			"port": 8123,
			"service_type": "_http._tcp"
		},
		{
			"hostname": "paperless.local",
			"ip": "192.168.1.102"
		}
	]`

	tmpFile, err := os.CreateTemp("", "hosts-*.json")
	if err != nil {
		t.Fatalf("failed to create temp file: %v", err)
	}
	defer os.Remove(tmpFile.Name())

	if _, err := tmpFile.WriteString(data); err != nil {
		t.Fatalf("failed to write temp file: %v", err)
	}
	tmpFile.Close()

	hosts, err := loadManualHosts(tmpFile.Name())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(hosts) != 2 {
		t.Fatalf("expected 2 hosts, got %d", len(hosts))
	}

	if hosts[0].Hostname != "homeassistant.local" || hosts[0].Port != 8123 {
		t.Errorf("host 0 mismatch: %+v", hosts[0])
	}
	if hosts[1].Hostname != "paperless.local" || hosts[1].Port != 0 {
		t.Errorf("host 1 mismatch: %+v", hosts[1])
	}
}
