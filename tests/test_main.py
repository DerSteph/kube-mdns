from argparse import Namespace
import unittest
from unittest.mock import Mock, patch
from src.kubernetes_utils.kubernetes_watcher import KubernetesWatcher
from src.kubernetes_utils.kubernetes_service import KubernetesService

from src import main
from src.zeroconf_utils.zeroconf_service import ZeroconfService


class TestMain(unittest.TestCase):
    @patch("src.core.argparse_factory.ArgparseFactory.create")
    @patch("src.core.core_service.CoreService")
    @patch("src.kubernetes_utils.kubernetes_watcher_factory.KubernetesWatcherFactory.create")
    @patch("src.zeroconf_utils.zeroconf_service_factory.ZeroconfServiceFactory.create")
    @patch("src.ingress_storage.ingress_storage.IngressStorage")
    @patch("src.kubernetes_utils.kubernetes_factory.KubernetesFactory.create")
    def test_main_success(self, kubernetes_factory, storage_service, zc_factory, kw_factory, core_service, argparse_factory):
        kubernetes_service = Mock(spec=KubernetesService)

        kubernetes_factory.return_value = kubernetes_service

        zeroconf_service = Mock(spec=ZeroconfService)

        zc_factory.return_value = zeroconf_service

        kubernetes_watcher = Mock(spec=KubernetesWatcher)

        kw_factory.return_value = kubernetes_watcher
        
        argparse = Mock(config=None)
        
        argparse_factory.return_value = argparse

        main.main()
        
        kubernetes_factory.assert_called()
        
        kubernetes_watcher.start.assert_called_once()
    
    @patch("src.core.argparse_factory.ArgparseFactory.create")
    @patch("src.core.core_service.CoreService")
    @patch("src.kubernetes_utils.kubernetes_watcher_factory.KubernetesWatcherFactory.create")
    @patch("src.zeroconf_utils.zeroconf_service_factory.ZeroconfServiceFactory.create")
    @patch("src.ingress_storage.ingress_storage.IngressStorage")
    @patch("src.kubernetes_utils.kubernetes_factory.KubernetesFactory.create") 
    def test_main_throws_exception(self, kubernetes_factory, storage_service, zc_factory, kw_factory, core_service, argparse_factory):
        kubernetes_service = Mock(spec=KubernetesService)

        kubernetes_factory.return_value = kubernetes_service

        zeroconf_service = Mock(spec=ZeroconfService)

        zc_factory.return_value = zeroconf_service

        kubernetes_watcher = Mock(spec=KubernetesWatcher)

        kw_factory.return_value = kubernetes_watcher
        
        kubernetes_watcher.start.side_effect = Exception()
        
        argparse = Mock(config=None)
        
        argparse_factory.return_value = argparse

        with self.assertRaises(SystemExit) as cm:
            main.main()
            
        self.assertEqual(cm.exception.code, 70)
        
        kubernetes_factory.assert_called()
        
        kubernetes_watcher.start.assert_called_once()
        
        zeroconf_service.force_remove_all_records.assert_called()


if __name__ == '__main__':
    unittest.main()
