#!/usr/bin/env python

import logging
import os
import sys
from permanent_host_storage.permanent_host_json_loader import PermanentHostJsonLoader
from permanent_host_storage.permanent_host_storage import PermanentHostStorage
from src.core.argparse_factory import ArgparseFactory
from src.kubernetes_utils.kubernetes_factory import KubernetesFactory
from src.core.core_service import CoreService
from src.kubernetes_utils.kubernetes_watcher import KubernetesWatcher
from src.kubernetes_utils.kubernetes_watcher_factory import KubernetesWatcherFactory
from src.ingress_storage.ingress_storage import IngressStorage
from src.zeroconf_utils.zeroconf_service_factory import ZeroconfServiceFactory
from src.zeroconf_utils.zeroconf_service import ZeroconfService


def main():
    args = ArgparseFactory.create()

    logging.basicConfig(format='%(asctime)s - %(message)s', level=logging.INFO)

    logging.info("Starting kube-mdns service...")

    KubernetesFactory.create(debug=args.debug)

    ingress_storage: IngressStorage = IngressStorage()

    permanent_hosts_storage = PermanentHostStorage()

    zeroconf_service: ZeroconfService = ZeroconfServiceFactory.create(
        logging.getLogger("zeroconfService"),
        ingress_storage,
        permanent_hosts_storage
    )

    if args.config is not None:
        permanent_storage_json_loader = PermanentHostJsonLoader(
            args.config
        )

        permanent_hosts_vo = permanent_storage_json_loader.extract_data()

        zeroconf_service.init_permanent_hosts(
            permanent_hosts_vo
        )

    kubernetes_watcher: KubernetesWatcher = KubernetesWatcherFactory.create(
        zeroconf_service,
        ingress_storage
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
