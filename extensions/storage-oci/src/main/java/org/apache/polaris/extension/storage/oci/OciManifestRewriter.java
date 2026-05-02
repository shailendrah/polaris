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
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.HashSet;
import java.util.Set;
import org.apache.iceberg.Snapshot;
import org.apache.iceberg.TableMetadata;
import org.apache.iceberg.io.FileIO;
import org.apache.iceberg.io.PositionOutputStream;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Per-snapshot avro post-processor: walks each snapshot's manifest-list and the manifest avros it
 * references, copies them with all {@code s3a?://} URIs rewritten to OCI native URLs, and stores
 * the rewritten copies alongside the originals.
 *
 * <p>The rewritten avros use the same on-disk schema as the originals — the only delta is the
 * URI strings inside record fields. Iceberg readers (including ADW's iceberg engine) can consume
 * them indistinguishably from the originals.
 *
 * <p><b>What this does</b>
 *
 * <ol>
 *   <li>For each snapshot in {@code current}, fetch its manifest-list avro from {@code io}.
 *   <li>Run it through {@link GenericAvroRewriter} (URI strings rewritten anywhere in the
 *       record tree).
 *   <li>Write the rewritten manifest-list to a sibling path with a {@code .oci.avro} suffix.
 *   <li>For each {@code manifest_path} referenced from the rewritten list, do the same — read
 *       the manifest avro, rewrite, write to {@code <original>.oci.avro}.
 * </ol>
 *
 * <p><b>What this DOES NOT do (yet)</b>
 *
 * <ul>
 *   <li>Build a new {@link TableMetadata} that points at the rewritten avros — that's the
 *       caller's job (e.g. the iceberg-REST commit handler), because the catalog also needs to
 *       persist the new {@code metadata-location}.
 *   <li>Rewrite delete-file manifests separately. Format-version 2 stores delete files via the
 *       same manifest avro structure (with a {@code content} field set to {@code 1} or {@code 2});
 *       since we round-trip the entire record generically, those URIs are also caught.
 *   <li>Touch {@code metadata-log} entries — those reference earlier {@code metadata.json} files
 *       and must remain pointing at the original on-disk versions.
 * </ul>
 */
public final class OciManifestRewriter {

  private static final Logger LOGGER = LoggerFactory.getLogger(OciManifestRewriter.class);

  /** Suffix appended to original avro paths to produce the rewritten copy's path. */
  static final String REWRITTEN_SUFFIX = ".oci.avro";

  private final OciUriRewriter uriRewriter;
  private final GenericAvroRewriter avroRewriter;
  private final FileIO io;

  public OciManifestRewriter(@Nonnull OciUriRewriter uriRewriter, @Nonnull FileIO io) {
    this.uriRewriter = uriRewriter;
    this.avroRewriter = new GenericAvroRewriter(uriRewriter);
    this.io = io;
  }

  /**
   * Rewrites every avro file referenced by every snapshot in {@code current}, producing
   * {@code <original>.oci.avro} sibling files. Returns the set of original→rewritten path pairs
   * actually written so callers can build a new metadata.json that points at them.
   */
  public RewrittenPaths rewriteAll(@Nonnull TableMetadata current) throws IOException {
    RewrittenPaths result = new RewrittenPaths();
    Set<String> processedManifests = new HashSet<>();
    for (Snapshot snapshot : current.snapshots()) {
      String listPath = snapshot.manifestListLocation();
      if (listPath == null || result.containsManifestList(listPath)) {
        continue;
      }
      // Read the original manifest-list to find all manifests it references —
      // we need their original (s3://) paths to fetch the bytes. Then we
      // rewrite the list itself; the rewritten list will reference the
      // rewritten manifest paths because GenericAvroRewriter applies to every
      // string in the list's records.
      byte[] originalList = readAll(listPath);
      Set<String> referencedManifests = ManifestListIntrospector.manifestPaths(originalList);

      byte[] rewrittenList = avroRewriter.rewrite(originalList);
      String rewrittenListPath = listPath + REWRITTEN_SUFFIX;
      writeAll(rewrittenListPath, rewrittenList);
      result.addManifestList(listPath, rewrittenListPath);
      LOGGER.debug(
          "Rewrote manifest-list {} → {} ({} bytes, {} manifests)",
          listPath,
          rewrittenListPath,
          rewrittenList.length,
          referencedManifests.size());

      for (String manifestPath : referencedManifests) {
        if (!processedManifests.add(manifestPath)) {
          continue;
        }
        byte[] originalManifest = readAll(manifestPath);
        byte[] rewrittenManifest = avroRewriter.rewrite(originalManifest);
        String rewrittenManifestPath = manifestPath + REWRITTEN_SUFFIX;
        writeAll(rewrittenManifestPath, rewrittenManifest);
        result.addManifest(manifestPath, rewrittenManifestPath);
        LOGGER.debug(
            "Rewrote manifest {} → {} ({} bytes)",
            manifestPath,
            rewrittenManifestPath,
            rewrittenManifest.length);
      }
    }
    return result;
  }

  // -- IO helpers (kept simple; no streaming because manifest avros are tiny) --

  private byte[] readAll(String path) throws IOException {
    try (InputStream in = io.newInputFile(path).newStream()) {
      ByteArrayOutputStream bos = new ByteArrayOutputStream();
      byte[] buf = new byte[8192];
      int n;
      while ((n = in.read(buf)) >= 0) {
        bos.write(buf, 0, n);
      }
      return bos.toByteArray();
    }
  }

  private void writeAll(String path, byte[] bytes) throws IOException {
    try (PositionOutputStream out = io.newOutputFile(path).createOrOverwrite()) {
      out.write(bytes);
    }
  }

  OciUriRewriter uriRewriter() {
    return uriRewriter;
  }

  FileIO io() {
    return io;
  }
}
