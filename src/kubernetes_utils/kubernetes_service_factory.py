import logging
from kubernetes import client, config

from src.kubernetes_utils.kubernetes_service import KubernetesService


class KubernetesServiceFactory:
    @staticmethod
    def create(logger: logging.Logger) -> KubernetesService:
        config.load_incluster_config()

        return KubernetesService(
            logger,
            client.CoreV1Api(),
            client.NetworkingV1Api()
        )
