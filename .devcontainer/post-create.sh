#!/usr/bin/env bash
# Post-create: install the lint tooling so `make lint` works inside the
# devcontainer.
set -euo pipefail

sudo apt-get update -qq
sudo apt-get install -y -qq shellcheck make

pip install --user --quiet \
  'ansible-core==2.18.*' \
  'ansible-lint==25.*' \
  'yamllint==1.37.*' \
  'pre-commit'

ansible-galaxy collection install community.general ansible.posix

# Install the pre-commit hooks if the repo doesn't have a .git directory
# already (Codespaces sometimes shallow-clones without .git).
if [ -d .git ]; then
  pre-commit install
fi

echo
echo "✓ devcontainer ready. Try:"
echo "    make lint          # ansible-lint + shellcheck + yamllint"
echo "    make validate      # preflight (NOTE: many checks are host-only)"
echo "    make setup-check   # ansible dry-run"
