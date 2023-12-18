import json
import logging
from typing import Any, Set
from src.permanent_host_storage.permanent_host_value_object import PermanentHostValueObject


class PermanentHostJsonLoader:
    _filepath: str

    def __init__(
        self,
        filepath: str
    ):
        self._filepath = filepath

    def extract_data(self):
        json_data = self._load_json()

        return self._get_permanent_hosts(json_data)

    def _load_json(self) -> Any:
        try:
            return json.loads(self._filepath)
        except json.JSONDecodeError:
            logging.error("Could not load json from config path")

    def _get_permanent_hosts(self, json_data) -> Set[PermanentHostValueObject]:
        permanent_hosts = set()

        for value in json_data:
            hostname = value["hostname"]
            ip = value["ip"]

            permanent_hosts.add(
                PermanentHostValueObject(
                    hostname,
                    ip
                )
            )
        
        return permanent_hosts
