import logging
from kubernetes import watch, client

from src.kubernetes_utils.ingress_value_object import IngressValueObject
from src.ingress_storage.ingress_storage import IngressStorage
from src.zeroconf_utils.zeroconf_service import ZeroconfService
from src.kubernetes_utils.config import Config


class KubernetesWatcher:
    def __init__(
        self,
        watch_instance: watch.Watch,
        networking_v1_api: client.NetworkingV1Api,
        storage_service: IngressStorage,
        zeroconf_service: ZeroconfService,
    ):
        self._watcher = watch_instance
        self._networking_api = networking_v1_api
        self._storage_service = storage_service
        self._zeroconf_service = zeroconf_service

    def start(self):
        for event in self._watcher.stream(
            self._networking_api.list_ingress_for_all_namespaces
        ):
            match event['type']:  # type: ignore
                case Config.ADDED:
                    logging.debug('--> Added detected')
                    self.check_added_ingress(event['object'])  # type: ignore
                case Config.DELETED:
                    logging.debug('--> Deleted detected')
                    self.check_deleted_ingress(event['object'])  # type: ignore
                case Config.MODIFIED:
                    logging.debug('--> Modified detected')
                    self.check_modified_ingress(
                        event['object'])  # type: ignore

    def check_added_ingress(self, ingress):
        namespace_name = ingress.metadata.namespace

        ingress_name = ingress.metadata.name

        ip_addresses_object = ingress.status.load_balancer.ingress

        if ip_addresses_object is None:
            return

        ip_addresses = []

        for ip_object in ip_addresses_object:
            ip_addresses.append(ip_object.ip)

        mdns_hostnames = []

        for rule in ingress.spec.rules:
            if rule.host is not None and rule.host.endswith(Config.MDNS_SUFFIX):
                mdns_hostnames.append(rule.host)

        if not mdns_hostnames:
            return

        if self._storage_service.find_by_namespace_name_and_ingress_name(
            namespace_name,
            ingress_name
        ) is not None:
            logging.warning(
                'Ingress entity in storage was found when ingress was added')
            return

        ingress_vo = IngressValueObject(
            namespace_name,
            ingress_name,
            mdns_hostnames
        )

        self._zeroconf_service.create_record(ingress_vo, ip_addresses)

    def check_deleted_ingress(self, ingress):
        namespace_name = ingress.metadata.namespace

        ingress_name = ingress.metadata.name

        ingress_entity = self._storage_service.find_by_namespace_name_and_ingress_name(
            namespace_name,
            ingress_name
        )

        if ingress_entity is None:
            logging.warning(
                'Ingress entity in storage was not found when ingress was removed')
            return

        self._zeroconf_service.delete_record(
            ingress_entity
        )

    def check_modified_ingress(self, ingress):
        namespace_name = ingress.metadata.namespace

        ingress_name = ingress.metadata.name

        ip_addresses_object = ingress.status.load_balancer.ingress

        if ip_addresses_object is None:
            return

        ip_addresses = []

        for ip_object in ip_addresses_object:
            ip_addresses.append(ip_object.ip)

        found_ingress_entity = self._storage_service.find_by_namespace_name_and_ingress_name(
            namespace_name,
            ingress_name
        )

        if found_ingress_entity is None:
            # modified ingress had no mdns / .local records in the rules before, so we will create one
            self.check_added_ingress(ingress)
            return

        event_hostnames = []

        for rule in ingress.spec.rules:
            hostname = rule.host

            if hostname.endswith(Config.MDNS_SUFFIX) is True:
                event_hostnames.append(hostname)

        # only new event hostnames with .local -> add
        diff1 = list(set(event_hostnames) -
                     set(found_ingress_entity.list_mdns_hostnames()))

        # only current hostnames -> remove
        diff2 = list(
            set(found_ingress_entity.list_mdns_hostnames()) - set(event_hostnames))

        for hostname in diff2:
            self._zeroconf_service.remove_hostname_of_record(
                found_ingress_entity, hostname)

        for hostname in diff1:
            self._zeroconf_service.add_hostname_to_record(
                found_ingress_entity, hostname, ip_addresses)
