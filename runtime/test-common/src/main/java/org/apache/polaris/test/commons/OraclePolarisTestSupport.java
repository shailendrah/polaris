/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */
package org.apache.polaris.test.commons;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.sql.Statement;

/**
 * Test-only helper for the Oracle relational-JDBC backend. Drops and recreates the
 * {@code POLARIS_SCHEMA} user so each test method starts against an empty schema.
 *
 * <p>Reads the Oracle connection from {@code QUARKUS_DATASOURCE_JDBC_URL},
 * {@code QUARKUS_DATASOURCE_USERNAME}, and {@code QUARKUS_DATASOURCE_PASSWORD}. The configured
 * user must hold DBA-level privileges (DROP USER, CREATE USER, GRANT UNLIMITED TABLESPACE) — this
 * is intended for local dev / CI against a disposable Oracle, not production.
 *
 * <p>If the env vars are not set, {@link #resetPolarisSchema()} returns silently so tests that do
 * not target Oracle are unaffected.
 */
public final class OraclePolarisTestSupport {

  private static final String SCHEMA_USER = "POLARIS_SCHEMA";

  private OraclePolarisTestSupport() {}

  public static void resetPolarisSchema() {
    String url = System.getenv("QUARKUS_DATASOURCE_JDBC_URL");
    String user = System.getenv("QUARKUS_DATASOURCE_USERNAME");
    String pwd = System.getenv("QUARKUS_DATASOURCE_PASSWORD");
    if (url == null || user == null || pwd == null) {
      return;
    }
    try (Connection c = DriverManager.getConnection(url, user, pwd)) {
      execIgnoring(c, "DROP USER " + SCHEMA_USER + " CASCADE", 1918);
      exec(c, "CREATE USER " + SCHEMA_USER + " NO AUTHENTICATION");
      exec(c, "GRANT UNLIMITED TABLESPACE TO " + SCHEMA_USER);
    } catch (SQLException e) {
      throw new RuntimeException("Failed to reset POLARIS_SCHEMA", e);
    }
  }

  private static void exec(Connection c, String sql) throws SQLException {
    try (Statement st = c.createStatement()) {
      st.execute(sql);
    }
  }

  private static void execIgnoring(Connection c, String sql, int ignoredErrorCode)
      throws SQLException {
    try (Statement st = c.createStatement()) {
      st.execute(sql);
    } catch (SQLException e) {
      if (e.getErrorCode() != ignoredErrorCode) {
        throw e;
      }
    }
  }
}
