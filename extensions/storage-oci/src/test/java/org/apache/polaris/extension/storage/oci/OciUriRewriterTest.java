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

class OciUriRewriterTest {

  private final OciUriRewriter rewriter = new OciUriRewriter("axydmvgg0v5v", "us-sanjose-1");

  @Test
  void rewritesS3Scheme() {
    assertThat(rewriter.rewrite("s3://polaris-iceberg/demo/users/metadata/v3.metadata.json"))
        .isEqualTo(
            "https://objectstorage.us-sanjose-1.oraclecloud.com"
                + "/n/axydmvgg0v5v/b/polaris-iceberg/o/demo/users/metadata/v3.metadata.json");
  }

  @Test
  void rewritesS3aScheme() {
    assertThat(rewriter.rewrite("s3a://polaris-iceberg/demo/orders/data/0.parquet"))
        .isEqualTo(
            "https://objectstorage.us-sanjose-1.oraclecloud.com"
                + "/n/axydmvgg0v5v/b/polaris-iceberg/o/demo/orders/data/0.parquet");
  }

  @Test
  void preservesEmptyKey() {
    // bucket-only s3:// URI (rare but legal) — key segment is empty.
    assertThat(rewriter.rewrite("s3://polaris-iceberg"))
        .isEqualTo("https://objectstorage.us-sanjose-1.oraclecloud.com/n/axydmvgg0v5v/b/polaris-iceberg/o/");
  }

  @Test
  void leavesHttpsUnchanged() {
    String https = "https://example.com/some/path";
    assertThat(rewriter.rewrite(https)).isEqualTo(https);
  }

  @Test
  void leavesIcebergMetadataReferencesUnchangedWhenNotS3() {
    // A FileIO might reference a data file via the absolute path written by an
    // OCI-native writer; we must not double-rewrite.
    String already =
        "https://objectstorage.us-sanjose-1.oraclecloud.com"
            + "/n/axydmvgg0v5v/b/polaris-iceberg/o/already/native.parquet";
    assertThat(rewriter.rewrite(already)).isEqualTo(already);
  }

  @Test
  void leavesNullSafeFalseSafeForNonRewritable() {
    assertThat(OciUriRewriter.isRewritable(null)).isFalse();
    assertThat(OciUriRewriter.isRewritable("file:///tmp/x")).isFalse();
    assertThat(OciUriRewriter.isRewritable("s3://bucket/key")).isTrue();
    assertThat(OciUriRewriter.isRewritable("s3a://bucket/key")).isTrue();
  }
}
