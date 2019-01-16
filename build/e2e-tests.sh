#!/bin/bash

# Copyright 2018 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail

declare -a mandatory
mandatory=(
  NODE_IP
  SLOW_E2E_THRESHOLD
  PKG
  FOCUS
  E2E_NODES
)

missing=false
for var in ${mandatory[@]}; do
  if [[ -z "${!var+x}" ]]; then
    echo "Environment variable $var must be set"
    missing=true
  fi
done

if [ "$missing" = true ];then
  exit 1
fi

SCRIPT_ROOT=$(dirname ${BASH_SOURCE})/..

kubectl create ns xiyar-test
bash ./test/e2e/wait-for-nginx.sh xiyar-test

ginkgo build ./test/e2e

exec --                                      \
ginkgo                                       \
    -randomizeSuites                         \
    -randomizeAllSpecs                       \
    -flakeAttempts=2                         \
    --focus=${FOCUS}                         \
    -p                                       \
    -trace                                   \
    -nodes=${E2E_NODES}                      \
    -slowSpecThreshold=${SLOW_E2E_THRESHOLD} \
    -v                                       \
    -stream                                  \
    test/e2e/e2e.test
