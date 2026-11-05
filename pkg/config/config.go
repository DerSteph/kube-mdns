package config

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
)

type ManualHost struct {
	Hostname    string `json:"hostname"`
	IP          string `json:"ip"`
	Port        int    `json:"port,omitempty"`
	ServiceType string `json:"service_type,omitempty"`
}

type Config struct {
	Debug       bool
	Logging     string
	Interface   string
	Port        int
	ServiceType string
	ConfigPath  string
	EnableCRD   bool
	ManualHosts []ManualHost
}

func ParseFlags() (*Config, error) {
	cfg := &Config{}

	flag.BoolVar(&cfg.Debug, "debug", false, "Use local kubeconfig (~/.kube/config) instead of in-cluster config")
	flag.StringVar(&cfg.Logging, "logging", "INFO", "Log level (DEBUG, INFO, WARN, ERROR)")
	flag.StringVar(&cfg.Interface, "interface", "", "Network interface to bind mDNS server (e.g. eth0, eno1)")
	flag.IntVar(&cfg.Port, "port", 0, "Default port to advertise when not specified in Ingress")
	flag.StringVar(&cfg.ServiceType, "service-type", "_http._tcp", "Default mDNS service type")
	flag.StringVar(&cfg.ConfigPath, "config", "", "Path to manual hosts JSON config file")
	flag.BoolVar(&cfg.EnableCRD, "enable-crd", false, "Enable CRD operator mode")

	flag.Parse()

	if cfg.ConfigPath != "" {
		hosts, err := loadManualHosts(cfg.ConfigPath)
		if err != nil {
			return nil, fmt.Errorf("failed to load manual hosts from %s: %w", cfg.ConfigPath, err)
		}
		cfg.ManualHosts = hosts
	}

	return cfg, nil
}

func loadManualHosts(path string) ([]ManualHost, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	var hosts []ManualHost
	if err := json.Unmarshal(data, &hosts); err != nil {
		return nil, err
	}

	return hosts, nil
}
