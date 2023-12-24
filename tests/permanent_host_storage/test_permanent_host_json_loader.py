import os
import unittest
from src.permanent_host_storage.json_validate_error_exception import JsonValidateErrorException
from src.permanent_host_storage.json_load_error_exception import JsonLoadErrorException

from src.permanent_host_storage.permanent_host_json_loader import PermanentHostJsonLoader


class TestPermanentHostJsonLoader(unittest.TestCase):
    def test_extract_data_success(self):
        filepath = os.path.join(os.path.dirname(
            __file__), 'fixtures/config_success.json')

        permanent_host_json_loader = PermanentHostJsonLoader(
            filepath
        )

        actual_list = permanent_host_json_loader.extract_data()

        actual_vo = actual_list[0]

        self.assertEqual('test.local', actual_vo.hostname)

    def test_extract_data_load_json_failure(self):
        filepath = os.path.join(os.path.dirname(
            __file__), 'fixtures/config_damaged.json')

        permanent_host_json_loader = PermanentHostJsonLoader(
            filepath
        )

        with self.assertRaises(JsonLoadErrorException):
            permanent_host_json_loader.extract_data()

    def test_extract_data_json_validate_failure(self):
        filepath = os.path.join(os.path.dirname(
            __file__), 'fixtures/config_wrong_schema.json')

        permanent_host_json_loader = PermanentHostJsonLoader(
            filepath
        )

        with self.assertRaises(JsonValidateErrorException):
            permanent_host_json_loader.extract_data()


if __name__ == '__main__':
    unittest.main()
