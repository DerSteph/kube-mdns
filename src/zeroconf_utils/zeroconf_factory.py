import logging
import ifaddr
import zeroconf

class ZeroconfFactory:
    @staticmethod
    def create(
        interface: str | None
        ) -> zeroconf.Zeroconf:
            if interface is None:
                return zeroconf.Zeroconf(zeroconf.InterfaceChoice.Default)
        
            logging.info("Try using interface %s for mdns", interface)
        
            ip_addresses_of_interface = []

            adapters = ifaddr.get_adapters()
            
            for adapter in adapters:
                if adapter.name == interface:
                    for ip in adapter.ips:
                        ip_addresses_of_interface.append(ip.ip)
        
            return zeroconf.Zeroconf(ip_addresses_of_interface)