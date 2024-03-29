import logging

import zeroconf
from src.permanent_host_storage.permanent_host_storage import PermanentHostStorage
from src.ingress_storage.ingress_storage import IngressStorage
from src.zeroconf_utils.zeroconf_service import ZeroconfService


class ZeroconfServiceFactory:
    @staticmethod
    def create(
        logger: logging.Logger,
        ingress_storage: IngressStorage,
        permanent_hosts_storage: PermanentHostStorage,
        zeroconf: zeroconf.Zeroconf,
        service_type: str
    ) -> ZeroconfService:
        return ZeroconfService(
            logger,
            zeroconf,
            ingress_storage,
            permanent_hosts_storage,
            service_type
        )
