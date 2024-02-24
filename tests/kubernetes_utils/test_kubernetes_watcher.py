import unittest
from unittest.mock import Mock

from src.kubernetes_utils.kubernetes_watcher import KubernetesWatcher
from src.ingress_storage.ingress_entity import IngressEntity
from src.ingress_storage.ingress_storage import IngressStorage
from src.zeroconf_utils.zeroconf_service import ZeroconfService


class TestKubernetesWatcher(unittest.TestCase):
    def test_added_ingress(self):
        rule = Mock()

        rule.host = "test.local"

        ingress = Mock()

        ingress.metadata.namespace = "TestNamespace"

        ingress.metadata.name = "TestIngress"

        ingress.spec.rules = [
            rule
        ]

        ip = Mock()

        ip.ip = "192.168.1.2"
        
        port_object = Mock()
        
        port_object.port = 443
        
        ip.ports = [port_object]

        ingress.status.load_balancer.ingress = [
            ip
        ]

        watcher = Mock()

        watcher.stream.return_value = [
            {
                'type': 'ADDED',
                'object': ingress
            }
        ]

        networking_api = Mock()

        storage_service = Mock(spec=IngressStorage)

        storage_service.find_by_namespace_name_and_ingress_name.return_value = None

        zeroconf_service = Mock(spec=ZeroconfService)

        kub_watcher = KubernetesWatcher(
            watcher,
            networking_api,
            storage_service,
            zeroconf_service,
        )

        kub_watcher.start()

        zeroconf_service.create_record.assert_called_once()

    def test_deleted_ingress(self):
        rule = Mock()

        rule.host = "test.local"

        ingress = Mock()

        ingress.metadata.namespace = "TestNamespace"

        ingress.metadata.name = "TestIngress"

        ingress.spec.rules = [
            rule
        ]

        ip = Mock()

        ip.ip = "192.168.1.2"

        ingress.status.load_balancer.ingress = [
            ip
        ]

        watcher = Mock()

        watcher.stream.return_value = [
            {
                'type': 'DELETED',
                'object': ingress
            }
        ]

        networkingApi = Mock()

        storage_service = Mock(spec=IngressStorage)

        storage_service.find_by_namespace_name_and_ingress_name.return_value = Mock(
            spec=IngressEntity)

        zeroconf_service = Mock(spec=ZeroconfService)

        kubWatcher = KubernetesWatcher(
            watcher,
            networkingApi,
            storage_service,
            zeroconf_service
        )

        kubWatcher.start()

        zeroconf_service.delete_record.assert_called_once()

    def test_modified_ingress(self):
        rule = Mock()

        rule.host = "test_new.local"

        ingress = Mock()

        ingress.metadata.namespace = "TestNamespace"

        ingress.metadata.name = "TestIngress"

        ingress.spec.rules = [
            rule
        ]

        ip = Mock()

        ip.ip = "192.168.1.2"

        port_object = Mock()
        
        port_object.port = 443
        
        ip.ports = [port_object]

        ingress.status.load_balancer.ingress = [
            ip
        ]

        watcher = Mock()

        watcher.stream.return_value = [
            {
                'type': 'MODIFIED',
                'object': ingress,
            }
        ]

        networking_api = Mock()

        storage_service = Mock(spec=IngressStorage)

        ingress_entity_mock = Mock(spec=IngressEntity)

        ingress_entity_mock.list_mdns_hostnames.return_value = [
            'test_old.local'
        ]

        storage_service.find_by_namespace_name_and_ingress_name.return_value = ingress_entity_mock

        zeroconf_service = Mock(spec=ZeroconfService)

        kub_watcher = KubernetesWatcher(
            watcher,
            networking_api,
            storage_service,
            zeroconf_service
        )

        kub_watcher.start()

        zeroconf_service.remove_hostname_of_record.assert_called_with(
            ingress_entity_mock, 'test_old.local')

        zeroconf_service.add_hostname_to_record.assert_called_with(ingress_entity_mock, 'test_new.local', [
            '192.168.1.2'
        ], 443)


if __name__ == '__main__':
    unittest.main()
