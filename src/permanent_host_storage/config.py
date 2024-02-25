class Config:
    JSON_SCHEMA = {
        "$schema": "http://json-schema.org/draft-04/schema#",
        "type": "array",
        "items": [
            {
                "type": "object",
                "properties": {
                    "hostname": {
                        "type": "string"
                    },
                    "ip": {
                        "type": "string"
                    },
                    "port": {
                        "type": "integer"
                    },
                    "service_type": {
                        "type": "string"
                    }
                },
                "required": [
                    "hostname",
                    "ip"
                ]
            }
        ]
    }
