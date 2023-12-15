import logging
from kubernetes import config

class KubernetesFactory:
    @staticmethod
    def create(debug: bool):
        if debug is False:
            logging.info("Using incluster config for kubernetes connection")
            config.load_incluster_config()
        else:
            logging.info("Using kubeconfig for kubernetes connection")
            config.load_kube_config()