import unittest
from unittest.mock import Mock

from src.kubernetes_connector.kubernetes_watcher import KubernetesWatcher
from src.storage.ingress_entity import IngressEntity
from src.storage.storage_service import StorageService
from src.zeroconf_manager.zeroconf_service import ZeroconfService

class TestkubernetesWatcher(unittest.TestCase):
    def test_StartAddedEvent(self):
        rule = Mock()
        
        rule.host = "test.local"
        
        ingress = Mock()
        
        ingress.spec.rules = [
            rule
        ]
        
        watcher = Mock()
        
        watcher.stream.return_value = [
            {
                'type': 'ADDED',
                'object': ingress
            }
        ]
        
        networkingApi = Mock()
        
        storage_service = Mock(spec=StorageService)
        
        storage_service.find_by_namespace_name_and_ingress_name.return_value = None
        
        zeroconf_service = Mock(spec=ZeroconfService)
        
        kubWatcher = KubernetesWatcher(
            watcher,
            networkingApi,
            storage_service,
            zeroconf_service
        )
        
        kubWatcher.start()
        
        zeroconf_service.create_record.assert_called_once()

    def test_StartDeletedEvent(self):
        rule = Mock()
        
        rule.host = "test.local"
        
        ingress = Mock()
        
        ingress.spec.rules = [
            rule
        ]
        
        watcher = Mock()
        
        watcher.stream.return_value = [
            {
                'type': 'DELETED',
                'object': ingress
            }
        ]
        
        networkingApi = Mock()
        
        storage_service = Mock(spec=StorageService)
        
        storage_service.find_by_namespace_name_and_ingress_name.return_value = Mock(spec=IngressEntity)
        
        zeroconf_service = Mock(spec=ZeroconfService)
        
        kubWatcher = KubernetesWatcher(
            watcher,
            networkingApi,
            storage_service,
            zeroconf_service
        )
        
        kubWatcher.start()
        
        zeroconf_service.delete_record.assert_called_once()
        
    def test_StartCheckModified(self):
        currentHost = Mock()
        
        currentHost.host = "test_new.local"
        
        ingress = Mock()
        
        ingress.spec.rules = [
            currentHost
        ]
        
        watcher = Mock()
        
        watcher.stream.return_value = [
            {
                'type': 'MODIFIED',
                'object': ingress,
            }
        ]
        
        networkingApi = Mock()
        
        storage_service = Mock(spec=StorageService)
        
        ingress_entity_mock = Mock(spec=IngressEntity)
        
        ingress_entity_mock.list_mdns_hostnames.return_value = [
            'test_old.local'
        ]
        
        storage_service.find_by_namespace_name_and_ingress_name.return_value = ingress_entity_mock
        
        zeroconf_service = Mock(spec=ZeroconfService)
        
        kubWatcher = KubernetesWatcher(
            watcher,
            networkingApi,
            storage_service,
            zeroconf_service
        )
        
        kubWatcher.start()
        
        zeroconf_service.remove_hostname_of_record.assert_called_with(ingress_entity_mock, 'test_old.local')
        
        zeroconf_service.add_hostname_to_record.assert_called_with(ingress_entity_mock, 'test_new.local')

if __name__ == '__main__':
    unittest.main()