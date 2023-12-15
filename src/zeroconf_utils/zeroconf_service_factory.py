import logging

import zeroconf
from src.storage.storage_service import StorageService
from src.zeroconf_utils.zeroconf_service import ZeroconfService


class ZeroconfServiceFactory:
    @staticmethod
    def create(logger: logging.Logger, storage_service: StorageService) -> ZeroconfService:
        zc = zeroconf.Zeroconf()

        return ZeroconfService(
            logger,
            zc,
            storage_service
        )
