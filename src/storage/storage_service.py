from typing import Set
from src.storage.ingress_entity import IngressEntity


class StorageService:
    _storage: Set[IngressEntity] = set()

    def add(self, entity: IngressEntity):
        self._storage.add(entity)

    def find_by_namespace_name_and_ingress_name(self, namespace_name: str, ingress_name: str) -> IngressEntity | None:
        for value in self._storage:
            if (value.get_namespace_name() == namespace_name and
                    value.get_ingress_name() == ingress_name):
                return value
        return None

    def remove(self, entity: IngressEntity):
        self._storage.remove(entity)
