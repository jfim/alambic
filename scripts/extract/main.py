# /// script
# requires-python = ">=3.11"
# ///
"""Dummy extraction model.

Receives an HTML file path on argv[1] (ignored). Emits a stub XPath result
on stdout as JSON. Replaced by a real model later without changes on the
Elixir side as long as the output schema is preserved.
"""
import json
import sys

_ = sys.argv[1:]  # input path ignored by the dummy
print(json.dumps({"xpath": "/", "confidence": None}))
