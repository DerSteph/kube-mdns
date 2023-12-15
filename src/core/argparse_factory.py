import argparse


class ArgparseFactory:
    @staticmethod
    def create() -> argparse.Namespace:
        parser = argparse.ArgumentParser(allow_abbrev=False)

        parser.add_argument("--debug", action="store_true")

        parser.add_argument("--config", action="store")

        return parser.parse_args()
