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

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Records the original→rewritten path mappings produced by {@link OciManifestRewriter#rewriteAll}.
 * Caller uses these to build a new {@code metadata.json} that points at the rewritten copies.
 */
public final class RewrittenPaths {
  private final Map<String, String> manifestLists = new LinkedHashMap<>();
  private final Map<String, String> manifests = new LinkedHashMap<>();

  void addManifestList(String original, String rewritten) {
    manifestLists.put(original, rewritten);
  }

  void addManifest(String original, String rewritten) {
    manifests.put(original, rewritten);
  }

  boolean containsManifestList(String original) {
    return manifestLists.containsKey(original);
  }

  /** Map of original manifest-list path → rewritten manifest-list path. */
  public Map<String, String> manifestLists() {
    return Map.copyOf(manifestLists);
  }

  /** Map of original manifest path → rewritten manifest path. */
  public Map<String, String> manifests() {
    return Map.copyOf(manifests);
  }
}
