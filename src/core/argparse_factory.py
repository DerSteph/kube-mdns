import argparse
import os


class ArgparseFactory:
    @staticmethod
    def create() -> argparse.Namespace:
        parser = argparse.ArgumentParser(allow_abbrev=False)

        parser.add_argument("--debug", action="store_true", help="When set, will use kubernetes kubeconfig instead of incluster config")
        
        parser.add_argument("--logging", action="store", help="Set logging level by value")

        parser.add_argument("--config", action="store", type=ArgparseFactory.validate_file, help="Set config by value")
        
        parser.add_argument("--interface", action="store", help="Set preferred interface for mDNS by value")
        
        parser.add_argument("--port", action="store", help="Set default port when port is not found in ingress")

        return parser.parse_args()

    @staticmethod
    def validate_file(file):
        expanded_path = os.path.expanduser(file)
        
        if not os.path.exists(expanded_path):
            raise argparse.ArgumentTypeError("{0} does not exist".format(file))
        
        return expanded_path