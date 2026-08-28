#!/bin/bash
# Run AFTER CI is green and the AF_API_KEY secret is set:
# promotes the current main branch to prod, which builds and deploys
# gm-bmd.act.gymnation.com.
cd "$(dirname "$0")"
git push origin main:prod && echo "" && echo "Deploy started — watch it at:" && echo "https://github.com/grantsharples91/gm-bmd/actions"
