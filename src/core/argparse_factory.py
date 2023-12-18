import argparse
import os


class ArgparseFactory:
    @staticmethod
    def create() -> argparse.Namespace:
        parser = argparse.ArgumentParser(allow_abbrev=False)

        parser.add_argument("--debug", action="store_true")

        parser.add_argument("--config", action="store", type=validate_file)

        return parser.parse_args()

    @staticmethod
    def validate_file(f):
        if not os.path.exists(f):
            raise argparse.ArgumentTypeError("{0} does not exist".format(f))
        return f