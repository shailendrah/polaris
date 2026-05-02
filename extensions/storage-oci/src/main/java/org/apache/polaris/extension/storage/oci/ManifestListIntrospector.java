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
import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.util.LinkedHashSet;
import java.util.Set;
import org.apache.avro.file.DataFileStream;
import org.apache.avro.generic.GenericDatumReader;
import org.apache.avro.generic.GenericRecord;

/**
 * Reads an iceberg manifest-list avro and returns the set of {@code manifest_path} values it
 * references. Used by {@link OciManifestRewriter} to know which manifest avros to fetch and
 * rewrite.
 *
 * <p>Schema-agnostic: works with both format-version 1 and 2 manifest lists because the
 * {@code manifest_path} field is present in both.
 */
final class ManifestListIntrospector {

  private ManifestListIntrospector() {}

  static Set<String> manifestPaths(@Nonnull byte[] manifestListBytes) throws IOException {
    Set<String> paths = new LinkedHashSet<>();
    try (DataFileStream<GenericRecord> reader =
        new DataFileStream<>(
            new ByteArrayInputStream(manifestListBytes), new GenericDatumReader<>())) {
      for (GenericRecord record : reader) {
        Object pathField = record.get("manifest_path");
        if (pathField != null) {
          paths.add(pathField.toString());
        }
      }
    }
    return paths;
  }
}
