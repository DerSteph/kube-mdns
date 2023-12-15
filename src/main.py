#!/usr/bin/env python

import logging
import os
import sys
from src.core.argparse_factory import ArgparseFactory
from src.kubernetes_utils.kubernetes_factory import KubernetesFactory
from src.core.core_service import CoreService
from src.kubernetes_utils.kubernetes_watcher import KubernetesWatcher
from src.kubernetes_utils.kubernetes_watcher_factory import KubernetesWatcherFactory
from src.storage.storage_service import StorageService
from src.zeroconf_utils.zeroconf_service_factory import ZeroconfServiceFactory
from src.zeroconf_utils.zeroconf_service import ZeroconfService


def main():
    args = ArgparseFactory.create()
    
    logging.basicConfig(format='%(asctime)s - %(message)s', level=logging.INFO)

    logging.info("Starting kube-mdns service...")

    KubernetesFactory.create(debug=args.debug)

    storage_service: StorageService = StorageService()

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
        logging.exception(
            "Error occured! Shutdown mdns service and unregister services")

        zeroconf_service.force_remove_all_records()

        sys.exit(os.EX_SOFTWARE)


if __name__ == "__main__":
    main()
