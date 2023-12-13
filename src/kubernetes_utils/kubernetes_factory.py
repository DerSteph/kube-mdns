from kubernetes import config

class KubernetesFactory:
    @staticmethod
    def create(debug: bool):
        if debug is False:
            config.load_incluster_config()
        else:
            config.load_kube_config()