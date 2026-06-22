#!/usr/bin/env sh
set -u -e

echo "..running pre-commit checks.."

zig build 2>/dev/null || { echo -e "\033[0;31mfailed to build the project\033[0m"; exit 1;}

printf "OK!\n"

exit 0
