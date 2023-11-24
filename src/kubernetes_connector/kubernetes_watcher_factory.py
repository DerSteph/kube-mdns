from src.kubernetes_connector.kubernetes_watcher import KubernetesWatcher

from kubernetes import watch, client
from src.storage.storage_service import StorageService

from src.zeroconf_manager.zeroconf_service import ZeroconfService


class KubernetesWatcherFactory:
    @staticmethod
    def create(
        zeroconfService: ZeroconfService,
        storageService: StorageService
    ) -> KubernetesWatcher:
        return KubernetesWatcher(
            watch.Watch(),
            client.NetworkingV1Api(),
            storageService,
            zeroconfService,
        )
