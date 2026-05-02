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
package org.apache.polaris.core.storage.oci;

import com.fasterxml.jackson.annotation.JsonIgnore;
import com.fasterxml.jackson.annotation.JsonTypeName;
import com.fasterxml.jackson.databind.annotation.JsonDeserialize;
import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import jakarta.annotation.Nullable;
import org.apache.polaris.core.storage.PolarisStorageConfigurationInfo;
import org.apache.polaris.immutables.PolarisImmutable;

/**
 * Storage configuration for OCI Object Storage.
 *
 * <p>Backwards-compatible with S3-compatible writers (PyIceberg, Spark,
 * GoldenGate) — they continue to write {@code s3://<bucket>/<key>} URIs into
 * iceberg metadata via OCI's S3-compat (vhcompat) endpoint with HMAC
 * Customer Secret Keys. The catalog stores those URIs as-is.
 *
 * <p>On the read path, the iceberg-REST {@code LoadTable} response handler
 * rewrites {@code s3://<bucket>/<key>} → {@code https://objectstorage
 * .<region>.oraclecloud.com/n/<namespace>/b/<bucket>/o/<key>} so that ADW (and
 * any other reader that doesn't speak S3-compat) can fetch the data via OCI
 * native URLs and OCI native auth (API key signing). Manifest-list and
 * manifest avros are post-processed similarly so the URIs ADW eventually
 * follows are also OCI native.
 *
 * <p>The {@link StorageType#OCI_OBJECT_STORE} value still uses {@code s3://}
 * as its location prefix because that's what writers emit; the OCI-native
 * URLs only appear in iceberg-REST responses.
 */
@PolarisImmutable
@JsonSerialize(as = ImmutableOciStorageConfigurationInfo.class)
@JsonDeserialize(as = ImmutableOciStorageConfigurationInfo.class)
@JsonTypeName("OciStorageConfigurationInfo")
public abstract class OciStorageConfigurationInfo extends PolarisStorageConfigurationInfo {

  public static ImmutableOciStorageConfigurationInfo.Builder builder() {
    return ImmutableOciStorageConfigurationInfo.builder();
  }

  @Override
  public StorageType getStorageType() {
    return StorageType.OCI_OBJECT_STORE;
  }

  @Override
  public String getFileIoImplClassName() {
    // Writers use Iceberg's S3FileIO against OCI's vhcompat S3-compat endpoint;
    // Polaris itself uses the same FileIO for any server-side reads (e.g. when
    // post-processing manifest avros for URI rewriting).
    return "org.apache.iceberg.aws.s3.S3FileIO";
  }

  /** OCI tenancy namespace. Required to construct native URLs. */
  public abstract String getNamespace();

  /** OCI region (e.g. {@code us-sanjose-1}). Required to construct native URLs. */
  public abstract String getRegion();

  /**
   * S3-compat endpoint Polaris uses to read/write the underlying bytes (typically
   * vhcompat). Distinct from the native URLs we emit to readers. Optional;
   * defaults to vhcompat for the configured region.
   */
  @Nullable
  public abstract String getS3CompatEndpoint();

  /** OCI native objectstorage host (computed). */
  @JsonIgnore
  public String getNativeObjectStorageHost() {
    return "objectstorage." + getRegion() + ".oraclecloud.com";
  }
}
