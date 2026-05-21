# /// script
# requires-python = ">=3.11"
# ///
"""Dummy cleaning model.

Receives an extracted-text file path on argv[1] (ignored). Emits a stub
cleaned-text result on stdout as JSON.
"""
import json
import sys

_ = sys.argv[1:]
print(json.dumps({"cleaned_text": "foo", "confidence": None}))
