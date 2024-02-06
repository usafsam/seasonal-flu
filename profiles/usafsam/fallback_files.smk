'''
This file picks the first file that exists for the following keys:
	annotations
'''

import os.path

if "builds" not in config:
    config["builds"] = {}

for build_name, build_params in config["builds"].items():
    annotations = build_params.pop("annotations", None)

    if annotations is not None:
        for annotation in annotations:
            if os.path.isfile(annotation):
                config["builds"][build_name]["annotation"] = annotation
                break
