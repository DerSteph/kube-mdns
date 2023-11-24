import logging
import unittest
from unittest.mock import Mock

import kubernetes.client as client

from src.kubernetes_connector.kubernetes_service import KubernetesService

class TestkubernetesService(unittest.TestCase):
    def test_get_mdns_ingresses(self):
        logger = Mock(spec=logging.Logger)
        
        coreApi = Mock(spec=client.CoreV1Api)
        
        namespace = Mock()
        
        namespace.metadata.name = "NamespaceName"
        
        namespaceList = Mock()
        
        namespaceList.items = [namespace]
        
        coreApi.list_namespace.return_value = namespaceList
        
        rule = Mock()
        
        rule.host = "test.local"
        
        ingress = Mock()
        
        ingress.spec.rules = [rule]
        
        ingressList = Mock()
        
        ingressList.items = [ingress]
        
        networkingApi = Mock(spec=client.NetworkingV1Api)
        
        networkingApi.list_namespaced_ingress.return_value = ingressList
        
        
        kubernetesSer = KubernetesService(
            logger,
            coreApi,
            networkingApi
        )
        
        actual = kubernetesSer.get_mdns_ingresses()
        
        self.assertEqual(1, len(actual))
        self.assertEqual('NamespaceName', actual[0].namespace_name)
        
    def test_getExternalIpFromService(self):
        coreApi = Mock(spec=client.CoreV1Api)
        
        namespace = Mock()
        
        namespace.metadata.name = "NamespaceName"
        
        namespaceList = Mock()
        
        namespaceList.items = [namespace]
        
        externalIp1 = Mock()
        
        externalIp1.ip = "192.168.1.101"
        
        service = Mock()
        
        service.spec.type = "LoadBalancer"
        
        service.status.load_balancer.ingress = [externalIp1]
        
        serviceList = Mock()
        
        serviceList.items = [service]
        
        coreApi.list_namespace.return_value = namespaceList
        
        coreApi.list_namespaced_service.return_value = serviceList
        
        logger = Mock(spec=logging.Logger)
        
        networkingApi = Mock(spec=client.NetworkingV1Api)
        
        kubernetesSer = KubernetesService(
            logger,
            coreApi,
            networkingApi
        )
        
        actual = kubernetesSer.find_external_ip_from_load_balancer()
        
        self.assertEqual("192.168.1.101", actual)
        
if __name__ == '__main__':
    unittest.main()