#!/usr/bin/env bash
# Runs the playbook with the repo's ansible.cfg from any directory: ansible/run.sh [ansible-playbook args]
cd "$(dirname "${BASH_SOURCE[0]}")" && exec ansible-playbook verify.yml "$@"
