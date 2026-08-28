#!/bin/bash
# One-shot: pushes the gm-bmd dashboard code to GitHub (main branch).
cd "$(dirname "$0")"
git push -u origin main && echo "" && echo "DONE — code is on GitHub. CI is now running at:" && echo "https://github.com/grantsharples91/gm-bmd/actions"
