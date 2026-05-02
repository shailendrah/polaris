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
import org.apache.iceberg.TableMetadata;
import org.apache.iceberg.TableMetadataParser;

/**
 * Rewrites all {@code s3://<bucket>/<key>} URIs inside an Iceberg {@link TableMetadata} to OCI
 * native URLs.
 *
 * <p>Iceberg's {@code TableMetadata} is immutable and contains URIs in many places:
 * {@code location}, every snapshot's {@code manifest-list}, statistics file paths, partition
 * statistics file paths, and metadata-log entries. Rather than enumerate and rebuild via
 * {@code TableMetadata.Builder} (which would couple us to every iceberg-spec field), we serialize
 * to JSON via {@link TableMetadataParser}, regex-rewrite all {@code s3a?://} URIs in the JSON
 * string, and parse it back. {@code s3://} only appears in URI position in iceberg metadata
 * JSON (it's never used as a plain string value), so this is safe.
 */
public final class TableMetadataRewriter {

  /** Matches {@code "s3://...} or {@code "s3a://...} appearing as a JSON string value. */
  private static final Pattern S3_IN_JSON =
      Pattern.compile("\"s3a?://([^\"]+)\"");

  private final OciUriRewriter uriRewriter;

  public TableMetadataRewriter(@Nonnull OciUriRewriter uriRewriter) {
    this.uriRewriter = uriRewriter;
  }

  /**
   * Returns a new {@link TableMetadata} with every {@code s3://} URI rewritten to its OCI native
   * form. Returns the input unchanged if no rewrites apply.
   */
  public TableMetadata rewrite(@Nonnull TableMetadata metadata) {
    String json = TableMetadataParser.toJson(metadata);
    String rewritten = rewriteJson(json);
    if (rewritten.equals(json)) {
      return metadata;
    }
    // The metadata-file location is what TableMetadata stores as its
    // "metadata file location"; we keep it stable by passing null (parser
    // pulls it from the JSON if present).
    return TableMetadataParser.fromJson(rewritten);
  }

  /** Visible for testing — applies the regex rewrite without re-parsing. */
  String rewriteJson(@Nonnull String json) {
    Matcher m = S3_IN_JSON.matcher(json);
    StringBuffer sb = new StringBuffer();
    while (m.find()) {
      String original = "s3" + (m.group(0).charAt(3) == 'a' ? "a" : "") + "://" + m.group(1);
      String replaced = uriRewriter.rewrite(original);
      // Re-quote and escape regex replacement metacharacters.
      m.appendReplacement(sb, Matcher.quoteReplacement("\"" + replaced + "\""));
    }
    m.appendTail(sb);
    return sb.toString();
  }
}
