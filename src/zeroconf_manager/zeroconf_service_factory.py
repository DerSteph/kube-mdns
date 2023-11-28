import logging

import zeroconf
from src.storage.storage_service import StorageService
from src.zeroconf_manager.zeroconf_service import ZeroconfService


class ZeroconfServiceFactory:
    @staticmethod
    def create(logger: logging.Logger, storageService: StorageService) -> ZeroconfService:
        zc = zeroconf.Zeroconf()

        return ZeroconfService(
            logger,
            zc,
            storageService
        )
