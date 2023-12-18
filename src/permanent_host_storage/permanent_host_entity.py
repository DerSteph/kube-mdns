import zeroconf


class PermanentHostEntity:
    def __init__(
        self,
        hostname: str,
        service_info: zeroconf.ServiceInfo
    ):
        self._hostname = hostname
        self._service_info = service_info
        
    def get_hostname(self) -> str:
        return self._hostname
