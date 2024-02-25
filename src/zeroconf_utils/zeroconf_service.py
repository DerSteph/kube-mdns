import logging
import socket
from typing import List
import zeroconf
from src.permanent_host_storage.permanent_host_entity import PermanentHostEntity
from src.permanent_host_storage.permanent_host_storage import PermanentHostStorage
from src.permanent_host_storage.permanent_host_value_object import PermanentHostValueObject

from src.kubernetes_utils.ingress_value_object import IngressValueObject
from src.ingress_storage.ingress_entity import IngressEntity
from src.ingress_storage.ingress_storage import IngressStorage

DEFAULT_PORT = 443


class ZeroconfService:
    def __init__(
        self,
        logger: logging.Logger,
        zeroconf_instance: zeroconf.Zeroconf,
        storage_service: IngressStorage,
        permanent_hosts_storage: PermanentHostStorage,
        service_type : str
    ):
        self._logger = logger
        self._zeroconf_instance = zeroconf_instance
        self._storage_service = storage_service
        self._permanent_hosts_storage = permanent_hosts_storage
        self._service_type = service_type

    def init_permanent_hosts(
        self,
        permanent_hosts_vo: List[PermanentHostValueObject]
    ):
        permanent_hosts_entities = set()

        for permanent_host_vo in permanent_hosts_vo:
            without_local = permanent_host_vo.hostname.replace(".local", "")

            info = zeroconf.ServiceInfo(
                permanent_host_vo.service_type or self._service_type,
                f"{without_local}.{permanent_host_vo.service_type or self._service_type}",
                addresses=[socket.inet_aton(permanent_host_vo.ip)],
                port=permanent_host_vo.port or DEFAULT_PORT,
                server=f"{permanent_host_vo.hostname}."
            )
            
            try:
                self._zeroconf_instance.register_service(
                    info
                )

                self._logger.info(
                    f"Published {permanent_host_vo.hostname} for load balancer ip {permanent_host_vo.ip} by manual config")

                permanent_hosts_entities.add(
                    PermanentHostEntity(
                        permanent_host_vo.hostname,
                        info
                    )
                )
            except (zeroconf.NonUniqueNameException, zeroconf.ServiceNameAlreadyRegistered):
                self._logger.error(
                    f"Hostname {permanent_host_vo.hostname} is already published in the network. Skipped..."
                )

        self._permanent_hosts_storage.init_storage(
            permanent_hosts_entities
        )

    def force_remove_all_records(self):
        self._zeroconf_instance.unregister_all_services()
        self._zeroconf_instance.close()

    def create_record(self, ingress_vo: IngressValueObject, ip_addresses: list[str], preferred_port : int | None):
        hostname_dict = {}

        ip_addresses_in_bytes = []

        for ip in ip_addresses:
            ip_addresses_in_bytes.append(
                socket.inet_aton(ip)
            )

        for hostname in ingress_vo.hostnames:
            # check for already manual defined hostnames
            if self._permanent_hosts_storage.find_by_hostname(
                hostname
            ) is not None:
                self._logger.info(
                    f"{hostname} has already been defined by manual config. Will be skipped")

                continue

            without_local = hostname.replace(".local", "")

            info = zeroconf.ServiceInfo(
                self._service_type,
                f"{without_local}.{self._service_type}",
                addresses=ip_addresses_in_bytes,
                port=preferred_port,
                server=f"{hostname}."
            )
            try:
                self._zeroconf_instance.register_service(info)
                
                hostname_dict[hostname] = info

                self._logger.info(
                    f"Published {hostname} for load balancer ips {','.join(ip_addresses)}")
            except (zeroconf.ServiceNameAlreadyRegistered, zeroconf.NonUniqueNameException):
                self._logger.error(
                    f"Hostname {hostname} is already published in the network. Skipped..."
                )

        self._storage_service.add(
            IngressEntity(
                ingress_vo.namespace_name,
                ingress_vo.ingress_name,
                hostname_dict
            )
        )

    def add_hostname_to_record(self, ingress_entity: IngressEntity, hostname: str, ip_addresses: list[str], preferred_port: int | None):
        # check for already manual defined hostnames
        if self._permanent_hosts_storage.find_by_hostname(
            hostname
        ) is not None:
            self._logger.info(
                f"{hostname} has already been defined by manual config. Will be skipped")

            return

        without_local = hostname.replace(".local", "")

        ip_addresses_in_bytes = []

        for ip in ip_addresses:
            ip_addresses_in_bytes.append(
                socket.inet_aton(ip)
            )

        info = zeroconf.ServiceInfo(
            self._service_type,
            f"{without_local}.{self._service_type}",
            addresses=ip_addresses_in_bytes,
            port=preferred_port,
            server=f"{hostname}."
        )

        try:
            self._zeroconf_instance.register_service(info)

            ingress_entity.add_mdns_entry(
                hostname,
                info
            )

            self._logger.info(
                f"Published {hostname} for load balancer ip {','.join(ip_addresses)}")
        except (zeroconf.ServiceNameAlreadyRegistered, zeroconf.NonUniqueNameException):
            self._logger.error(
                f"Hostname {hostname} is already published in the network. Skipped..."
            )

    def remove_hostname_of_record(self, ingress_entity: IngressEntity, hostname: str):
        service_info = ingress_entity.find_mdns_entry_by_hostname(hostname)

        # return if hostname not found anymore
        if service_info is None:
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
