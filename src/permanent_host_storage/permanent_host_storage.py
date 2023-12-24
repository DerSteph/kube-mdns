from typing import Set

from src.permanent_host_storage.permanent_host_entity import PermanentHostEntity


class PermanentHostStorage:
    _permanent_hosts: Set[PermanentHostEntity] = set()

    def find_by_hostname(
        self,
        hostname: str
    ) -> PermanentHostEntity | None:
        for value in self._permanent_hosts:
            if (value.get_hostname() == hostname):
                return value
        return None

    def init_storage(
        self,
        permanent_hosts: Set[PermanentHostEntity]
    ):
        self._permanent_hosts = permanent_hosts
