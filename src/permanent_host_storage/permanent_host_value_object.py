
from dataclasses import dataclass


@dataclass
class PermanentHostValueObject:
    hostname: str
    ip: str
