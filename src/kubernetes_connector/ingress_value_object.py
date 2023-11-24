from dataclasses import dataclass


@dataclass
class IngressValueObject:
    namespace_name: str
    ingress_name: str
    hostnames: list[str]
