package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/client-go/util/homedir"

	"github.com/net-pilgrim/kube-mdns/pkg/config"
	"github.com/net-pilgrim/kube-mdns/pkg/controller"
	"github.com/net-pilgrim/kube-mdns/pkg/mdns"
)

func main() {
	cfg, err := config.ParseFlags()
	if err != nil {
		log.Fatalf("Configuration error: %v", err)
	}

	log.Printf("Starting kube-mdns service...")

	// Initialize mDNS Manager
	mdnsMgr, err := mdns.NewManager(cfg.Interface, cfg.ServiceType)
	if err != nil {
		log.Fatalf("Failed to initialize mDNS manager: %v", err)
	}
	defer mdnsMgr.Shutdown()

	// Publish manual hosts from config if specified
	if len(cfg.ManualHosts) > 0 {
		log.Printf("Publishing %d manual host entry/entries...", len(cfg.ManualHosts))
		for i, h := range cfg.ManualHosts {
			port := h.Port
			if port == 0 {
				if cfg.Port > 0 {
					port = cfg.Port
				} else {
					port = 80
				}
			}
			key := fmt.Sprintf("manual-%d", i)
			_ = mdnsMgr.Publish(key, []mdns.Record{
				{
					Hostname:    h.Hostname,
					IPs:         []string{h.IP},
					Port:        port,
					ServiceType: h.ServiceType,
				},
			})
		}
	}

	// Initialize Kubernetes client
	k8sConfig, err := getKubernetesConfig(cfg.Debug)
	if err != nil {
		log.Printf("Warning: Failed to get Kubernetes config: %v. Running in standalone manual mode.", err)
		waitForSignal()
		return
	}

	clientset, err := kubernetes.NewForConfig(k8sConfig)
	if err != nil {
		log.Fatalf("Failed to create Kubernetes client: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Handle graceful shutdown
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	go func() {
		sig := <-sigCh
		log.Printf("Received termination signal (%v), shutting down...", sig)
		cancel()
	}()

	// Start Ingress Controller
	ingressCtrl := controller.NewIngressController(clientset, mdnsMgr, cfg.Port, 10*time.Minute)
	if err := ingressCtrl.Run(ctx); err != nil {
		log.Fatalf("Ingress controller error: %v", err)
	}

	log.Printf("kube-mdns shutdown complete. Goodbye!")
}

func getKubernetesConfig(debug bool) (*rest.Config, error) {
	if envKube := os.Getenv("KUBECONFIG"); envKube != "" {
		return clientcmd.BuildConfigFromFlags("", envKube)
	}

	if debug {
		var kubeconfigPath string
		if home := homedir.HomeDir(); home != "" {
			kubeconfigPath = filepath.Join(home, ".kube", "config")
		}
		return clientcmd.BuildConfigFromFlags("", kubeconfigPath)
	}

	// In-cluster configuration (uses service account token and ca.crt)
	cfg, err := rest.InClusterConfig()
	if err == nil {
		return cfg, nil
	}

	// Fallback to local ~/.kube/config if available
	if home := homedir.HomeDir(); home != "" {
		kubeconfigPath := filepath.Join(home, ".kube", "config")
		if _, err := os.Stat(kubeconfigPath); err == nil {
			return clientcmd.BuildConfigFromFlags("", kubeconfigPath)
		}
	}

	return nil, err
}

func waitForSignal() {
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	<-sigCh
	log.Printf("Exiting standalone mode.")
}
