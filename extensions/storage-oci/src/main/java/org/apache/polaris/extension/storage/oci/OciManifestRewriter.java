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
import org.apache.iceberg.TableMetadata;
import org.apache.iceberg.io.FileIO;

/**
 * Rewrites the on-disk avro files of a freshly-committed iceberg table snapshot so the
 * {@code data_file.file_path} fields inside manifests, and the {@code manifest_path} fields inside
 * the manifest-list, all point at OCI native URLs.
 *
 * <p>Workflow per commit:
 *
 * <ol>
 *   <li>For each {@code Snapshot} not yet rewritten, read its manifest-list avro.
 *   <li>For each {@code ManifestFile} in the list, read the manifest avro, write a new manifest
 *       avro (in a sibling location) where every {@code DataFile.path} is OCI native.
 *   <li>Write a new manifest-list pointing at the new manifests, with each
 *       {@code ManifestFile.path} also OCI native.
 *   <li>Build a new {@code TableMetadata} pointing at the new manifest list, write a new
 *       {@code metadata.json}, and return its location so the catalog can update its pointer.
 * </ol>
 *
 * <p>The original avros and metadata.json are never modified — they remain on disk for any
 * S3-compat reader that needs them. Polaris's catalog pointer for OCI catalogs always points at
 * the rewritten metadata.json.
 *
 * <p><b>Implementation status:</b> skeleton only. The avro round-trip uses iceberg's own
 * {@code ManifestFiles.read/write} and {@code ManifestLists.read/write} APIs, but careful
 * handling of:
 *
 * <ul>
 *   <li>format-version 1 vs 2 (partition spec evolution, sequence numbers)
 *   <li>partition specs map (Map of Integer to PartitionSpec, covering every historical spec)
 *   <li>delete files (v2) — separate manifest type
 *   <li>statistics file paths in {@code TableMetadata}
 *   <li>partition statistics file paths
 *   <li>existing {@code metadata-log} entries (must NOT be rewritten — they reference prior
 *       metadata.json files that are still on disk in their original form)
 * </ul>
 *
 * is required before this is production-ready. The {@link #rewrite} method below currently throws.
 */
public final class OciManifestRewriter {

  private final OciUriRewriter uriRewriter;
  private final FileIO io;

  public OciManifestRewriter(@Nonnull OciUriRewriter uriRewriter, @Nonnull FileIO io) {
    this.uriRewriter = uriRewriter;
    this.io = io;
  }

  /**
   * Rewrites a table's manifests and manifest-list to use OCI native URLs, then returns a new
   * {@link TableMetadata} pointing at the rewritten avros (with {@code metadata-location} suitable
   * for catalog persistence).
   *
   * @param current the just-committed metadata
   * @return a new metadata referencing rewritten avros
   * @throws UnsupportedOperationException until the implementation lands
   */
  public TableMetadata rewrite(@Nonnull TableMetadata current) {
    // Reserved for the avro round-trip implementation. See javadoc above for
    // the full list of fields that need rewriting.
    throw new UnsupportedOperationException(
        "OciManifestRewriter.rewrite is not yet implemented. "
            + "See class javadoc for the per-snapshot/per-manifest steps.");
  }

  OciUriRewriter uriRewriter() {
    return uriRewriter;
  }

  FileIO io() {
    return io;
  }
}
