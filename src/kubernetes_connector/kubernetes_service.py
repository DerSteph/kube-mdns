import logging

import kubernetes.client as client

from src.kubernetes_connector.ingress_value_object import IngressValueObject

MDNS_SUFFIX = ".local"

LOADBALANCER_STRING = "LoadBalancer"


class KubernetesService:
    def __init__(
        self,
        logger: logging.Logger,
        core_v1_api: client.CoreV1Api,
        networking_v1_api: client.NetworkingV1Api
    ):
        self._logger = logger

        self._core_api = core_v1_api

        self._networking_api = networking_v1_api

    def get_mdns_ingresses(self) -> list[IngressValueObject]:
        ingress_vo_list = []

        namespace_list = self._core_api.list_namespace()

        for namespace in namespace_list.items:
            namespace_name = namespace.metadata.name

            ingress_list = self._networking_api.list_namespaced_ingress(
                namespace=namespace_name)

            for ingress in ingress_list.items:

                ingress_name = ingress.metadata.name

                hostname = []

                for rule in ingress.spec.rules:
                    if rule.host and rule.host.endswith(MDNS_SUFFIX):
                        hostname.append(rule.host)
                        self._logger.info(
                            f"Found Hostname {rule.host} in Ingress {ingress.metadata.name}")

                if hostname != []:
                    ingress_vo = IngressValueObject(
                        namespace_name,
                        ingress_name,
                        hostname
                    )

                    ingress_vo_list.append(
                        ingress_vo
                    )

        return ingress_vo_list

    def find_external_ip_from_load_balancer(self) -> str | None:
        namespace_list = self._core_api.list_namespace()

        for namespace in namespace_list.items:
            namespace_name = namespace.metadata.name

            service_list = self._core_api.list_namespaced_service(
                namespace=namespace_name)

            for service in service_list.items:
                if service.spec.type == LOADBALANCER_STRING:
                    external_ips = service.status.load_balancer.ingress
                    if external_ips != None:
                        self._logger.info(
                            f"Found Service {service.metadata.name} of Ingress")
                        if external_ips[0].ip != None:
                            self._logger.info(
                                f"Found External IP {external_ips[0].ip} of Ingress")
                            return external_ips[0].ip
