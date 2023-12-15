import logging
import signal
from src.zeroconf_utils.zeroconf_service import ZeroconfService


class CoreService:
    def __init__(
        self,
        zeroconfService: ZeroconfService
    ):
        self.zeroconfService = zeroconfService

    def enable_signal_exit(self):
        signal.signal(signal.SIGINT, self.exit_gracefully)
        signal.signal(signal.SIGTERM, self.exit_gracefully)

    def exit_gracefully(self, signum, frame):
        logging.info(f"Received: {signum}")
        logging.info("Shutdown mdns service and unregister services")

        self.zeroconfService.force_remove_all_records()
