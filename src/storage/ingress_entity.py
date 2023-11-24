from typing import ItemsView, KeysView
import zeroconf


class IngressEntity:
    def __init__(
        self,
        namespace_name: str,
        ingress_name: str,
        hostnames_with_service_info: dict[str, zeroconf.ServiceInfo]
    ):
        self._namespace_name = namespace_name
        self._ingress_name = ingress_name
        self._hostnames_with_service_info = hostnames_with_service_info

    def get_namespace_name(self) -> str:
        return self._namespace_name

    def get_ingress_name(self) -> str:
        return self._ingress_name

    def add_mdns_entry(self, hostname: str, service_info: zeroconf.ServiceInfo):
        self._hostnames_with_service_info[hostname] = service_info

    def find_mdns_entry_by_hostname(self, hostname: str) -> zeroconf.ServiceInfo | None:
        return self._hostnames_with_service_info.get(hostname)

    def list_mdns_entries(self) -> ItemsView[str, zeroconf.ServiceInfo]:
        return self._hostnames_with_service_info.items()

    def list_mdns_hostnames(self) -> KeysView[str]:
        return self._hostnames_with_service_info.keys()

    def remove_mdns_entry(self, hostname: str):
        self._hostnames_with_service_info.pop(hostname)
