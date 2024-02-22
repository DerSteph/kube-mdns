import argparse
import os


class ArgparseFactory:
    @staticmethod
    def create() -> argparse.Namespace:
        parser = argparse.ArgumentParser(allow_abbrev=False)

        parser.add_argument("--debug", action="store_true")

        parser.add_argument("--config", action="store", type=ArgparseFactory.validate_file)
        
        parser.add_argument("--interface", action="store")

        return parser.parse_args()

    @staticmethod
    def validate_file(file):
        expanded_path = os.path.expanduser(file)
        
        if not os.path.exists(expanded_path):
            raise argparse.ArgumentTypeError("{0} does not exist".format(file))
        
        return expanded_path