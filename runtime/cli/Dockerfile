# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#
# Build the Apache Polaris Python CLI as a self-contained Docker image.
# Build context must be the repository root (the image needs both
# `client/python/` and `spec/`); see Makefile target docker-build-cli.

FROM python:3.13-slim

# Java is required by openapi-generator-cli (it shells out to a JAR).
RUN apt-get update \
    && apt-get install -y --no-install-recommends default-jre-headless curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Mirror the in-repo layout so generate_clients.py finds spec/ at ../../spec.
WORKDIR /work
COPY client/python/ /work/client/python/
COPY spec/ /work/spec/

# Generate the OpenAPI Python SDKs (apache_polaris.sdk.{management,catalog})
# and install the package so `polaris` is on PATH.
RUN pip install --no-cache-dir openapi-generator-cli==7.12.0 \
    && cd /work/client/python \
    && python generate_clients.py \
    && pip install --no-cache-dir .

# Drop privileges.
RUN groupadd --gid 10001 polaris \
    && useradd --uid 10000 --gid polaris polaris
USER polaris

ENTRYPOINT ["polaris"]
CMD ["--help"]
