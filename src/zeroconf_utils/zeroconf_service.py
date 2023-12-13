import logging
import socket
import zeroconf

from src.kubernetes_utils.ingress_value_object import IngressValueObject
from src.storage.ingress_entity import IngressEntity
from src.storage.storage_service import StorageService

SERVICE_TYPE = "_http._tcp.local."

PORT = 80  # for now, can be changed in the future


class ZeroconfService:
    def __init__(
        self,
        logger: logging.Logger,
        zeroconf_instance: zeroconf.Zeroconf,
        storage_service: StorageService
    ):
        self._logger = logger
        self._zeroconf_instance = zeroconf_instance
        self._storage_service = storage_service

    def force_remove_all_records(self):
        self._zeroconf_instance.unregister_all_services()
        self._zeroconf_instance.close()

    def create_record(self, ingress_vo: IngressValueObject, ip_addresses: list[str]):
        hostname_dict = {}

        ip_addresses_in_bytes = []

        for ip in ip_addresses:
            ip_addresses_in_bytes.append(
                socket.inet_aton(ip)
            )

        for hostname in ingress_vo.hostnames:
            without_local = hostname.replace(".local", "")

            info = zeroconf.ServiceInfo(
                SERVICE_TYPE,
                f"{without_local}.{SERVICE_TYPE}",
                addresses=ip_addresses_in_bytes,
                port=80,
                server=f"{hostname}."
            )

            self._zeroconf_instance.register_service(info)

            hostname_dict[hostname] = info

            self._logger.info(
                f"Published {hostname} for load balancer ips {','.join(ip_addresses)}")

        self._storage_service.add(
            IngressEntity(
                ingress_vo.namespace_name,
                ingress_vo.ingress_name,
                hostname_dict
            )
        )

    def add_hostname_to_record(self, ingress_entity: IngressEntity, hostname: str, ip_addresses: list[str]):
        without_local = hostname.replace(".local", "")

        ip_addresses_in_bytes = []

        for ip in ip_addresses:
            ip_addresses_in_bytes.append(
                socket.inet_aton(ip)
            )

        info = zeroconf.ServiceInfo(
            SERVICE_TYPE,
            f"{without_local}.{SERVICE_TYPE}",
            addresses=ip_addresses_in_bytes,
            port=80,
            server=f"{hostname}."
        )

        self._zeroconf_instance.register_service(info)

        ingress_entity.add_mdns_entry(
            hostname,
            info
        )

        self._logger.info(
            f"Published {hostname} for load balancer ip {','.join(ip_addresses)}")

    def remove_hostname_of_record(self, ingress_entity: IngressEntity, hostname: str):
        service_info = ingress_entity.find_mdns_entry_by_hostname(hostname)

        # return if hostname not found anymore
        if service_info == None:
            return

        self._zeroconf_instance.unregister_service(service_info)

        ingress_entity.remove_mdns_entry(hostname)

        ip_addresses_in_str = []

        for ip in service_info.addresses:
            ip_addresses_in_str.append(socket.inet_ntoa(ip))

        self._logger.info(
            f"Removed {hostname} from load balancer ip {','.join(ip_addresses_in_str)}")

    def delete_record(self, ingress_entity: IngressEntity):
        for hostname, service_info in ingress_entity.list_mdns_entries():
            self._zeroconf_instance.unregister_service(service_info)

            ip_addresses_in_str = []

            for ip in service_info.addresses:
                ip_addresses_in_str.append(socket.inet_ntoa(ip))

            self._logger.info(
                f"Removed {hostname} from load balancer ip {','.join(ip_addresses_in_str)}")

        self._storage_service.remove(ingress_entity)
