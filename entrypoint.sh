#!/bin/bash
set -e

echo "Running database setup and migrations..."
bin/alambic eval "Alambic.Release.create_and_migrate()"

echo "Starting application..."
exec bin/alambic start
