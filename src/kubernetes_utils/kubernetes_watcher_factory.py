from kubernetes import watch, client

from src.kubernetes_utils.kubernetes_watcher import KubernetesWatcher
from src.storage.storage_service import StorageService
from src.zeroconf_utils.zeroconf_service import ZeroconfService


class KubernetesWatcherFactory:
    @staticmethod
    def create(
        zeroconf_service: ZeroconfService,
        storage_service: StorageService
    ) -> KubernetesWatcher:
        return KubernetesWatcher(
            watch.Watch(),
            client.NetworkingV1Api(),
            storage_service,
            zeroconf_service,
        )
