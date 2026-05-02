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
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import org.junit.jupiter.api.Test;

class OciManifestRewriterTest {

  /**
   * Pinned skeleton-state assertion: until the avro round-trip is implemented, calling
   * {@code rewrite()} must throw with a clear "not implemented" message rather than silently
   * dropping files. When the implementation lands, replace this test with a real avro round-trip
   * that constructs a tiny manifest-list + manifest pair, runs them through the rewriter, and
   * asserts the resulting paths are OCI native.
   */
  @Test
  void rewriteIsExplicitlyUnimplementedSoCallersFailLoudly() {
    OciManifestRewriter rewriter =
        new OciManifestRewriter(new OciUriRewriter("axydmvgg0v5v", "us-sanjose-1"), null);
    assertThatThrownBy(() -> rewriter.rewrite(null))
        .isInstanceOf(UnsupportedOperationException.class)
        .hasMessageContaining("not yet implemented");
  }

  @Test
  void uriRewriterIsAccessibleForLaterIntegration() {
    OciUriRewriter inner = new OciUriRewriter("axydmvgg0v5v", "us-sanjose-1");
    OciManifestRewriter rewriter = new OciManifestRewriter(inner, null);
    assertThat(rewriter.uriRewriter()).isSameAs(inner);
  }
}
