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

import jakarta.annotation.Nonnull;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Translates {@code s3://<bucket>/<key>} URIs into OCI Object Storage native URLs of the form
 * {@code https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<bucket>/o/<key>}.
 *
 * <p>This is the central transform that lets Polaris serve OCI-native URLs to readers (e.g. ADW's
 * iceberg engine, which doesn't honor S3-compat endpoint overrides) while writers keep emitting
 * standard S3-style URIs against OCI's vhcompat endpoint.
 *
 * <p>This class is pure (no IO). It's used by:
 *
 * <ul>
 *   <li>The iceberg-REST {@code LoadTable} response builder, to rewrite {@code TableMetadata}
 *       fields ({@code location}, snapshot {@code manifest-list} paths) before serialization.
 *   <li>The post-commit avro post-processor, to rewrite {@code manifest_path} fields inside
 *       manifest-list avros and {@code data_file.file_path} fields inside manifest avros.
 * </ul>
 */
public final class OciUriRewriter {

  /**
   * Matches {@code s3://<bucket>/<key>} or {@code s3a://<bucket>/<key>}. Bucket: any non-slash
   * sequence (1+). Key: everything after the first slash following the bucket; can be empty.
   */
  private static final Pattern S3_URI = Pattern.compile("^s3a?://([^/]+)(?:/(.*))?$");

  private final String namespace;
  private final String region;

  public OciUriRewriter(@Nonnull String namespace, @Nonnull String region) {
    this.namespace = namespace;
    this.region = region;
  }

  /**
   * Rewrites a single URI. If it's an {@code s3://} or {@code s3a://} URI, returns the OCI native
   * form. Otherwise returns the input unchanged (idempotent).
   */
  public String rewrite(@Nonnull String uri) {
    Matcher m = S3_URI.matcher(uri);
    if (!m.matches()) {
      return uri;
    }
    String bucket = m.group(1);
    String key = m.group(2) == null ? "" : m.group(2);
    return String.format(
        "https://objectstorage.%s.oraclecloud.com/n/%s/b/%s/o/%s",
        region, namespace, bucket, key);
  }

  /**
   * Convenience: returns true if {@code uri} is one we'd rewrite. Useful when the caller wants to
   * skip serializing identity rewrites.
   */
  public static boolean isRewritable(String uri) {
    return uri != null && S3_URI.matcher(uri).matches();
  }
}
