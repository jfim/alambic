# /// script
# requires-python = ">=3.11"
# ///
import json, sys
payload = {"echoed": sys.argv[1] if len(sys.argv) > 1 else None}
print(json.dumps(payload))
