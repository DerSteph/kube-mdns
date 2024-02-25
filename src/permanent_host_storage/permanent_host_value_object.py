
from dataclasses import dataclass


@dataclass
class PermanentHostValueObject:
    hostname: str
    ip: str
    port: int | None
    service_type: str | None
