import unittest
from unittest.mock import Mock

import zeroconf

from src.storage.ingress_entity import IngressEntity


class TestIngressEntity(unittest.TestCase):
    def test_get_namespace_name(self):
        namespace_name = "TestNamespace"

        ingress_entity = IngressEntity(
            namespace_name,
            "testingress",
            {
                "hostname": Mock(spec=zeroconf.ServiceInfo)
            }
        )

        actual = ingress_entity.get_namespace_name()

        self.assertEqual(namespace_name, actual)

    def test_get_ingress_name(self):
        ingress_name = "TestIngress"

        ingress_entity = IngressEntity(
            "testnamespaces",
            ingress_name,
            {
                "hostname": Mock(spec=zeroconf.ServiceInfo)
            }
        )

        actual = ingress_entity.get_ingress_name()

        self.assertEqual(ingress_name, actual)

    def test_add_mdns_entry(self):
        ingress_entity = IngressEntity(
            "testnamespaces",
            "testingress",
            {}
        )

        expected = Mock(spec=zeroconf.ServiceInfo)

        ingress_entity.add_mdns_entry(
            "test.local",
            expected
        )

        actual = ingress_entity.find_mdns_entry_by_hostname(
            "test.local"
        )

        self.assertEqual(expected, actual)

    def test_remove_mdns_entry(self):
        ingress_entity = IngressEntity(
            "testnamespaces",
            "testingress",
            {
                "test.local": Mock(zeroconf.ServiceInfo)
            }
        )

        ingress_entity.remove_mdns_entry(
            "test.local"
        )

        actual = ingress_entity.find_mdns_entry_by_hostname(
            "test.local"
        )

        self.assertIsNone(actual)

    def test_list_mdns_entries(self):
        expected = {
            "test.local": Mock(zeroconf.ServiceInfo)
        }

        ingress_entity = IngressEntity(
            "testnamespaces",
            "testingress",
            expected
        )

        actual = ingress_entity.list_mdns_entries()

        self.assertEqual(1, len(actual))

        self.assertEqual(expected.items(), actual)

    def test_list_mdns_hostnames(self):
        expected = {
            "test.local": Mock(zeroconf.ServiceInfo)
        }

        ingress_entity = IngressEntity(
            "testnamespaces",
            "testingress",
            expected
        )

        actual = ingress_entity.list_mdns_hostnames()

        self.assertEqual(1, len(actual))
        self.assertEqual("test.local", list(actual)[0])


if __name__ == '__main__':
    unittest.main()
