#!/usr/bin/env python

import logging
from src.core.core_service import CoreService
from src.kubernetes_connector.kubernetes_service_factory import KubernetesServiceFactory
from src.kubernetes_connector.kubernetes_service import KubernetesService
from src.kubernetes_connector.kubernetes_watcher import KubernetesWatcher
from src.kubernetes_connector.kubernetes_watcher_factory import KubernetesWatcherFactory
from src.storage.storage_service import StorageService
from src.zeroconf_manager.zeroconf_service_factory import ZeroconfServiceFactory
from src.zeroconf_manager.zeroconf_service import ZeroconfService


def main():
    logging.basicConfig(format='%(asctime)s - %(message)s', level=logging.INFO)

    logging.info("Starting kube-mdns service...")

    kubernetes_service: KubernetesService = KubernetesServiceFactory.create(
        logging.getLogger('kubernetesService')
    )

    storage_service: StorageService = StorageService()

    #ip_address = kubernetes_service.find_external_ip_from_load_balancer()
    
    #if ip_address == None:
    #    logging.error("Could not find any ip address from service / loadbalencer for ingress to publish mdns adresses.")
    #    return

    zeroconf_service: ZeroconfService = ZeroconfServiceFactory.create(
        logging.getLogger("zeroconfService"),
        storage_service
    )

    kubernetes_watcher: KubernetesWatcher = KubernetesWatcherFactory.create(
        zeroconf_service,
        storage_service
    )

    core_service = CoreService(
        zeroconf_service
    )

    core_service.enable_signal_exit()

    try:
        logging.info(
            'Starting kube-mdns was successful. Start listening for incoming ingress changes...')
        kubernetes_watcher.start()
    except Exception:
        logging.exception("Error occured")
    finally:
        logging.info("Shutdown mdns service and unregister services")

        zeroconf_service.force_remove_all_records()


if __name__ == "__main__":
    main()
