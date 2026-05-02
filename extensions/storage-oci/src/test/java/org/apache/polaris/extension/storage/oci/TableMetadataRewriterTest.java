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
package org.apache.polaris.extension.storage.oci;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

class TableMetadataRewriterTest {

  private final TableMetadataRewriter rewriter =
      new TableMetadataRewriter(new OciUriRewriter("axydmvgg0v5v", "us-sanjose-1"));

  @Test
  void rewritesS3UrisInJson() {
    String json =
        "{"
            + "\"format-version\":2,"
            + "\"location\":\"s3://polaris-iceberg/demo/users\","
            + "\"current-snapshot-id\":42,"
            + "\"snapshots\":[{"
            + "\"snapshot-id\":42,"
            + "\"manifest-list\":\"s3://polaris-iceberg/demo/users/metadata/snap-42.avro\""
            + "}]"
            + "}";

    String rewritten = rewriter.rewriteJson(json);

    assertThat(rewritten)
        .doesNotContain("\"s3://")
        .contains(
            "\"https://objectstorage.us-sanjose-1.oraclecloud.com"
                + "/n/axydmvgg0v5v/b/polaris-iceberg/o/demo/users\"")
        // manifest-list specifically gets a .oci.avro suffix so readers reach
        // the rewritten copy.
        .contains(
            "\"manifest-list\":\"https://objectstorage.us-sanjose-1.oraclecloud.com"
                + "/n/axydmvgg0v5v/b/polaris-iceberg/o/demo/users/metadata/snap-42.avro.oci.avro\"");
  }

  @Test
  void rewritesS3aScheme() {
    String json = "{\"location\":\"s3a://bucket/path\"}";
    String rewritten = rewriter.rewriteJson(json);
    assertThat(rewritten)
        .isEqualTo(
            "{\"location\":\"https://objectstorage.us-sanjose-1.oraclecloud.com"
                + "/n/axydmvgg0v5v/b/bucket/o/path\"}");
  }

  @Test
  void leavesNonS3UrisAlone() {
    String json = "{\"location\":\"https://example.com/some/path\",\"x\":\"file:///tmp/y\"}";
    assertThat(rewriter.rewriteJson(json)).isEqualTo(json);
  }

  @Test
  void doesNotRewriteSubstringNamedS3() {
    // The string "s3" appearing inside a non-URI context must not be touched.
    String json = "{\"description\":\"backed by AWS s3 service\",\"location\":\"s3://b/k\"}";
    String rewritten = rewriter.rewriteJson(json);
    assertThat(rewritten).contains("\"backed by AWS s3 service\""); // untouched
    assertThat(rewritten)
        .contains("\"https://objectstorage.us-sanjose-1.oraclecloud.com/n/axydmvgg0v5v/b/b/o/k\"");
  }

  @Test
  void handlesSpecialRegexCharsInUri() {
    // Some keys end up containing dollar signs from snapshot UUIDs etc.
    String json = "{\"manifest-list\":\"s3://b/path-with-$-and-\\\\.escapes\"}";
    String rewritten = rewriter.rewriteJson(json);
    assertThat(rewritten).doesNotContain("\"s3://");
    assertThat(rewritten).contains("path-with-$-and-");
  }
}
