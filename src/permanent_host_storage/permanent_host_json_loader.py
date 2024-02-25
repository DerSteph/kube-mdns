import json
import logging
from typing import Any, List

import jsonschema
from src.permanent_host_storage.config import Config
from src.permanent_host_storage.json_load_error_exception import JsonLoadErrorException
from src.permanent_host_storage.json_validate_error_exception import JsonValidateErrorException
from src.permanent_host_storage.permanent_host_value_object import PermanentHostValueObject


class PermanentHostJsonLoader:
    _filepath: str

    def __init__(
        self,
        filepath: str
    ):
        self._filepath = filepath

    def extract_data(self) -> List[PermanentHostValueObject]:
        json_data = self._load_json()
        
        self._validate_json(json_data)

        return self._get_permanent_hosts(json_data)

    def _load_json(self) -> Any:
        try:
            with open(self._filepath, 'r', encoding='utf-8') as file:
                return json.load(file)
        except json.JSONDecodeError as ex:
            logging.error("Could not load json from config path")

            raise JsonLoadErrorException() from ex

    def _validate_json(self, json_data):
        try:
            jsonschema.validate(instance=json_data, schema=Config.JSON_SCHEMA)
        except jsonschema.ValidationError as ex:
            logging.error(
                "The provided json cannot be validated by the json schema")

            raise JsonValidateErrorException() from ex

    def _get_permanent_hosts(self, json_data) -> List[PermanentHostValueObject]:
        permanent_hosts = []

        for value in json_data:
            hostname = value["hostname"]
            ip = value["ip"]
            port = value.get("port")
            service_type = value.get("service_type")

            permanent_hosts.append(
                PermanentHostValueObject(
                    hostname,
                    ip,
                    port,
                    service_type
                )
            )

        return permanent_hosts
