import unittest
from unittest.mock import Mock

from zeroconf import ServiceInfo

from src.permanent_host_storage.permanent_host_entity import PermanentHostEntity
from src.permanent_host_storage.permanent_host_storage import PermanentHostStorage


class TestPermanentHostStorage(unittest.TestCase):
    def test_find_by_hostname_finds_entity(self):
        hostname = "TestHostname"
        
        entity = PermanentHostEntity(
            hostname,
            Mock(spec=ServiceInfo)
        )
        
        permanent_host_storage = PermanentHostStorage()
        
        permanent_host_storage.init_storage(
            {entity}
        )
        
        actual = permanent_host_storage.find_by_hostname(
            hostname
        )
        
        self.assertEqual(entity, actual)
    
    def test_find_by_hostname_finds_none(self):
        hostname = "TestHostname"
        
        hostname_not_findable = "TestNotFindable"
        
        entity = PermanentHostEntity(
            hostname,
            Mock(spec=ServiceInfo)
        )
        
        permanent_host_storage = PermanentHostStorage()
        
        permanent_host_storage.init_storage(
            {entity}
        )
        
        actual = permanent_host_storage.find_by_hostname(
            hostname_not_findable
        )
        
        self.assertIsNone(actual)

if __name__ == '__main__':
    unittest.main()
