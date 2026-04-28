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

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.sql.Statement;

/**
 * Drops and recreates the {@code POLARIS_SCHEMA} Oracle user so the next test/run starts against
 * an empty schema. Invoked by the Makefile and intended for local dev or CI against a disposable
 * Oracle instance.
 *
 * <p>Reads connection from system properties (preferred) or env vars:
 * <ul>
 *   <li>{@code QUARKUS_DATASOURCE_JDBC_URL}
 *   <li>{@code QUARKUS_DATASOURCE_USERNAME}
 *   <li>{@code QUARKUS_DATASOURCE_PASSWORD}
 * </ul>
 *
 * <p>Run via single-file source mode:
 * <pre>
 *   java -cp $OJDBC_JAR tools/scripts/PolarisSchemaReset.java
 * </pre>
 */
public class PolarisSchemaReset {

  public static void main(String[] args) throws Exception {
    String url = env("QUARKUS_DATASOURCE_JDBC_URL");
    String user = env("QUARKUS_DATASOURCE_USERNAME");
    String pwd = env("QUARKUS_DATASOURCE_PASSWORD");
    if (url == null || user == null || pwd == null) {
      System.err.println(
          "ERROR: Set QUARKUS_DATASOURCE_JDBC_URL, QUARKUS_DATASOURCE_USERNAME, "
              + "QUARKUS_DATASOURCE_PASSWORD before running.");
      System.exit(2);
    }

    String[] stmts = {
      "DROP USER POLARIS_SCHEMA CASCADE",
      "CREATE USER POLARIS_SCHEMA NO AUTHENTICATION",
      "GRANT UNLIMITED TABLESPACE TO POLARIS_SCHEMA"
    };

    try (Connection c = DriverManager.getConnection(url, user, pwd)) {
      for (String sql : stmts) {
        System.out.println("Executing: " + sql);
        try (Statement st = c.createStatement()) {
          st.execute(sql);
          System.out.println("  OK");
        } catch (SQLException e) {
          // 1918 = user does not exist (fine on first run); 1920 = user already exists.
          if (e.getErrorCode() == 1918 || e.getErrorCode() == 1920) {
            System.out.println("  -> " + e.getErrorCode() + " (ignored)");
          } else {
            throw e;
          }
        }
      }
    }
    System.out.println("POLARIS_SCHEMA reset complete.");
  }

  private static String env(String key) {
    String v = System.getProperty(key);
    if (v == null) v = System.getenv(key);
    return (v == null || v.isEmpty()) ? null : v;
  }
}
