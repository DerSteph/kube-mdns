package controller

import (
	"testing"

	networkingv1 "k8s.io/api/networking/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"

	"github.com/net-pilgrim/kube-mdns/pkg/mdns"
)

func TestResolvePort(t *testing.T) {
	fakeClient := fake.NewSimpleClientset()
	mdnsMgr, _ := mdns.NewManager("", "_http._tcp")
	ctrl := NewIngressController(fakeClient, mdnsMgr, 80, 0)

	// Case 1: Annotation port
	ing := &networkingv1.Ingress{
		ObjectMeta: metav1.ObjectMeta{
			Annotations: map[string]string{
				AnnPort: "8080",
			},
		},
	}
	if p := ctrl.resolvePort(ing, ing.Annotations); p != 8080 {
		t.Errorf("expected 8080 from annotation, got %d", p)
	}

	// Case 2: Status loadbalancer port
	port80 := int32(80)
	ingLB := &networkingv1.Ingress{
		Status: networkingv1.IngressStatus{
			LoadBalancer: networkingv1.IngressLoadBalancerStatus{
				Ingress: []networkingv1.IngressLoadBalancerIngress{
					{
						IP: "192.168.1.100",
						Ports: []networkingv1.IngressPortStatus{
							{Port: port80},
						},
					},
				},
			},
		},
	}
	if p := ctrl.resolvePort(ingLB, nil); p != 80 {
		t.Errorf("expected 80 from loadbalancer, got %d", p)
	}

	// Case 3: TLS fallback to 443
	ingTLS := &networkingv1.Ingress{
		Spec: networkingv1.IngressSpec{
			TLS: []networkingv1.IngressTLS{
				{Hosts: []string{"test.local"}},
			},
		},
	}
	ctrlNoDefault := NewIngressController(fakeClient, mdnsMgr, 0, 0)
	if p := ctrlNoDefault.resolvePort(ingTLS, nil); p != 443 {
		t.Errorf("expected 443 from TLS spec, got %d", p)
	}
}
