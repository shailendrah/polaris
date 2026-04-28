---
#
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
title: Relational JDBC
type: docs
weight: 100
---

This implementation leverages Quarkus for datasource management and supports configuration through
environment variables or JVM -D flags at startup. For more information, refer to the [Quarkus configuration reference](https://quarkus.io/guides/config-reference#env-file).

Use the following configuration for the Oracle relational JDBC backend:

## 1. Relational JDBC metastore with username and password

Using environment variables:

```properties
POLARIS_PERSISTENCE_TYPE=relational-jdbc

QUARKUS_DATASOURCE_USERNAME=<your-username>
QUARKUS_DATASOURCE_PASSWORD=<your-password>
QUARKUS_DATASOURCE_DB_KIND=oracle
QUARKUS_DATASOURCE_JDBC_URL=<jdbc-url-of-oracle>
```

Using properties file:

```properties
polaris.persistence.type=relational-jdbc
quarkus.datasource.jdbc.username=<your-username>
quarkus.datasource.jdbc.password=<your-password>
quarkus.datasource.db-kind=oracle
quarkus.datasource.jdbc.jdbc-url=<jdbc-url-of-oracle>
```

The Relational JDBC metastore relies on a Quarkus-managed datasource and is configured for Oracle.
Please refer to the documentation here:
[Configure data sources in Quarkus](https://quarkus.io/guides/datasource).

Additionally, the retries can be configured via `polaris.persistence.relational.jdbc.*` properties; please refer to the [Configuring Polaris]({{% ref "../configuration" %}}) section.

## Bootstrapping Polaris

Before using Polaris with the Relational JDBC backend, you must bootstrap the metastore to create the necessary schema and initial realm. This is done using the [Admin Tool]({{% ref "../admin-tool" %}}).

Using Docker:

```bash
docker run --rm -it \
  --env="polaris.persistence.type=relational-jdbc" \
  --env="quarkus.datasource.username=<your-username>" \
  --env="quarkus.datasource.password=<your-password>" \
  --env="quarkus.datasource.db-kind=oracle" \
  --env="quarkus.datasource.jdbc.url=<jdbc-url-of-oracle>" \
  apache/polaris-admin-tool:latest bootstrap -r <realm-name> -c <realm-name>,<client-id>,<client-secret>
```

Using the standalone JAR:

```bash
java \
  -Dpolaris.persistence.type=relational-jdbc \
  -Dquarkus.datasource.username=<your-username> \
  -Dquarkus.datasource.password=<your-password> \
  -Dquarkus.datasource.db-kind=oracle \
  -Dquarkus.datasource.jdbc.url=<jdbc-url-of-oracle> \
  -jar polaris-admin-tool.jar bootstrap -r <realm-name> -c <realm-name>,<client-id>,<client-secret>
```

For more details on the bootstrap command and other administrative operations, see the [Admin Tool]({{% ref "../admin-tool" %}}) documentation.
