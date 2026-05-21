# /// script
# requires-python = ">=3.11"
# ///
import json, sys
_ = sys.argv[1:]
print(json.dumps({"xpath": "/", "confidence": 0.2}))
