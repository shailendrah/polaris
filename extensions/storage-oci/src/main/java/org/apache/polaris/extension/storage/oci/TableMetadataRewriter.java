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

  /**
   * Matches the iceberg-metadata-spec {@code "manifest-list":"s3...avro"} field. We special-case
   * this to also append {@link OciManifestRewriter#REWRITTEN_SUFFIX} so the URI points readers at
   * the rewritten manifest-list copy on disk (which contains rewritten internal manifest-paths).
   */
  private static final Pattern MANIFEST_LIST_S3_IN_JSON =
      Pattern.compile("\"manifest-list\"\\s*:\\s*\"s3a?://([^\"]+)\"");

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
    // Pass 1: manifest-list fields get URI-rewrite + .oci.avro suffix so
    // readers fetch the rewritten copy (which has internal manifest_path
    // entries already pointing at the rewritten .oci.avro manifests).
    Matcher m1 = MANIFEST_LIST_S3_IN_JSON.matcher(json);
    StringBuffer pass1 = new StringBuffer();
    while (m1.find()) {
      // Reconstruct the full original URI from the captured group; the
      // captured part doesn't include the "s3://"/"s3a://" prefix.
      String original = m1.group(0).substring(m1.group(0).indexOf("\"s3") + 1);
      original = original.substring(0, original.length() - 1); // strip trailing quote
      String rewritten = uriRewriter.rewrite(original) + OciManifestRewriter.REWRITTEN_SUFFIX;
      m1.appendReplacement(
          pass1, Matcher.quoteReplacement("\"manifest-list\":\"" + rewritten + "\""));
    }
    m1.appendTail(pass1);

    // Pass 2: all remaining s3:// URIs get plain s3:// → https:// rewriting.
    Matcher m2 = S3_IN_JSON.matcher(pass1.toString());
    StringBuffer pass2 = new StringBuffer();
    while (m2.find()) {
      String original = m2.group(0).substring(1, m2.group(0).length() - 1); // strip outer quotes
      String replaced = uriRewriter.rewrite(original);
      m2.appendReplacement(pass2, Matcher.quoteReplacement("\"" + replaced + "\""));
    }
    m2.appendTail(pass2);
    return pass2.toString();
  }
}
