#!/bin/bash
set -e

# Install elan (Lean version manager)
curl -sSf https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -- -y --default-toolchain none

# Add elan to shell profiles
echo 'source $HOME/.elan/env' >> ~/.bashrc
echo 'source $HOME/.elan/env' >> ~/.zshrc

# Add .lake/build/bin to PATH
echo 'export PATH="$PWD/.lake/build/bin:$PATH"' >> ~/.bashrc
echo 'export PATH="$PWD/.lake/build/bin:$PATH"' >> ~/.zshrc

# Source elan and build
. $HOME/.elan/env
lake build react-agent
