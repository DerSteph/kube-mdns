package controller

import (
	"context"
	"fmt"
	"log"
	"strconv"
	"strings"
	"time"

	networkingv1 "k8s.io/api/networking/v1"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/cache"

	"github.com/net-pilgrim/kube-mdns/pkg/mdns"
)

const (
	AnnPrefix      = "mdns.net-pilgrim.dev"
	AnnEnabled     = "mdns.net-pilgrim.dev/enabled"
	AnnHostname    = "mdns.net-pilgrim.dev/hostname"
	AnnIP          = "mdns.net-pilgrim.dev/ip"
	AnnPort        = "mdns.net-pilgrim.dev/port"
	AnnServiceType = "mdns.net-pilgrim.dev/service-type"
	LblPublish     = "mdns.net-pilgrim.dev/publish"
)

type IngressController struct {
	client      kubernetes.Interface
	mdnsManager *mdns.Manager
	defaultPort int
	informer    cache.SharedIndexInformer
}

func NewIngressController(
	client kubernetes.Interface,
	mdnsManager *mdns.Manager,
	defaultPort int,
	resyncPeriod time.Duration,
) *IngressController {
	factory := informers.NewSharedInformerFactory(client, resyncPeriod)
	ingressInformer := factory.Networking().V1().Ingresses().Informer()

	c := &IngressController{
		client:      client,
		mdnsManager: mdnsManager,
		defaultPort: defaultPort,
		informer:    ingressInformer,
	}

	ingressInformer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc: func(obj interface{}) {
			ing, ok := obj.(*networkingv1.Ingress)
			if !ok {
				return
			}
			c.reconcile(ing)
		},
		UpdateFunc: func(oldObj, newObj interface{}) {
			ing, ok := newObj.(*networkingv1.Ingress)
			if !ok {
				return
			}
			c.reconcile(ing)
		},
		DeleteFunc: func(obj interface{}) {
			ing, ok := obj.(*networkingv1.Ingress)
			if !ok {
				tombstone, ok := obj.(cache.DeletedFinalStateUnknown)
				if !ok {
					return
				}
				ing, ok = tombstone.Obj.(*networkingv1.Ingress)
				if !ok {
					return
				}
			}
			key := fmt.Sprintf("%s/%s", ing.Namespace, ing.Name)
			c.mdnsManager.Unpublish(key)
		},
	})

	return c
}

func (c *IngressController) Run(ctx context.Context) error {
	log.Printf("Starting Kubernetes Ingress Controller watcher...")
	go c.informer.Run(ctx.Done())

	if !cache.WaitForCacheSync(ctx.Done(), c.informer.HasSynced) {
		return fmt.Errorf("timed out waiting for informer cache to sync")
	}

	log.Printf("Ingress Controller cache synced. Watching for Ingress changes...")
	<-ctx.Done()
	log.Printf("Shutting down Ingress Controller...")
	return nil
}

func (c *IngressController) reconcile(ing *networkingv1.Ingress) {
	key := fmt.Sprintf("%s/%s", ing.Namespace, ing.Name)

	annotations := ing.GetAnnotations()
	labels := ing.GetLabels()

	// Check if explicitly disabled
	if annotations[AnnEnabled] == "false" || labels[LblPublish] == "false" {
		c.mdnsManager.Unpublish(key)
		return
	}

	isForceEnabled := annotations[AnnEnabled] == "true" || labels[LblPublish] == "true"

	// Resolve IPs
	var ips []string
	if annIP, ok := annotations[AnnIP]; ok && annIP != "" {
		for _, part := range strings.Split(annIP, ",") {
			trimmed := strings.TrimSpace(part)
			if trimmed != "" {
				ips = append(ips, trimmed)
			}
		}
	} else {
		for _, lb := range ing.Status.LoadBalancer.Ingress {
			if lb.IP != "" {
				ips = append(ips, lb.IP)
			}
		}
	}

	if len(ips) == 0 {
		// Ingress has no LoadBalancer IP assigned yet and no annotation IP
		c.mdnsManager.Unpublish(key)
		return
	}

	// Resolve Port
	port := c.resolvePort(ing, annotations)

	// Resolve Service Type
	serviceType := annotations[AnnServiceType]

	// Resolve Hostnames
	var hostnames []string
	if annHost, ok := annotations[AnnHostname]; ok && annHost != "" {
		hostnames = append(hostnames, annHost)
	}

	for _, rule := range ing.Spec.Rules {
		host := rule.Host
		if host == "" {
			continue
		}
		if isForceEnabled || strings.HasSuffix(host, ".local") {
			// Avoid duplicate
			found := false
			for _, h := range hostnames {
				if h == host {
					found = true
					break
				}
			}
			if !found {
				hostnames = append(hostnames, host)
			}
		}
	}

	if len(hostnames) == 0 {
		c.mdnsManager.Unpublish(key)
		return
	}

	// Build records
	var records []mdns.Record
	for _, h := range hostnames {
		records = append(records, mdns.Record{
			Hostname:    h,
			IPs:         ips,
			Port:        port,
			ServiceType: serviceType,
		})
	}

	c.mdnsManager.Publish(key, records)
}

func (c *IngressController) resolvePort(ing *networkingv1.Ingress, annotations map[string]string) int {
	if annPort, ok := annotations[AnnPort]; ok && annPort != "" {
		if p, err := strconv.Atoi(annPort); err == nil && p > 0 {
			return p
		}
	}

	// Check status loadbalancer ports if available
	for _, lb := range ing.Status.LoadBalancer.Ingress {
		for _, p := range lb.Ports {
			if p.Port == 80 {
				return 80
			}
			if p.Port == 443 {
				return 443
			}
		}
		if len(lb.Ports) > 0 {
			return int(lb.Ports[0].Port)
		}
	}

	if c.defaultPort > 0 {
		return c.defaultPort
	}

	// Fallback: If TLS is configured on Ingress, default to 443, else 80
	if len(ing.Spec.TLS) > 0 {
		return 443
	}
	return 80
}
